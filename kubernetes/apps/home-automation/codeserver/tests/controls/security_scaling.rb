# frozen_string_literal: true

require 'yaml'

title 'CodeServer Security and Scaling Tests'

APP_DIR = File.expand_path('../../app', __dir__)
HELMRELEASE_PATH = File.join(APP_DIR, 'HelmRelease.yaml')
HTTPROUTE_PATH = File.join(APP_DIR, 'httproute.yaml')
EXTERNALSECRET_PATH = File.join(APP_DIR, 'externalsecret.yaml')
INTERCEPTORROUTE_PATH = File.join(APP_DIR, 'interceptorroute.yaml')
SCALEDOBJECT_PATH = File.join(APP_DIR, 'scaledobject.yaml')
REFERENCEGRANT_PATH = File.expand_path('../../../../keda/http-add-on/app/codeserver-referencegrant.yaml', __dir__)

FIRST_YAML = lambda do |path|
  YAML.load_stream(File.read(path)).first
end

control 'codeserver-auth-disabled-removed' do
  impact 1.0
  title 'CodeServer must not disable authentication'
  desc 'CodeServer must not run with --auth none'

  describe file(HELMRELEASE_PATH) do
    it { should exist }
    its('content') { should_not match(/--auth\s*\n\s*-\s*["']?none["']?/) }
    its('content') { should_not match(/--auth[=\s]+none/) }
  end
end

control 'codeserver-password-secret' do
  impact 1.0
  title 'CodeServer password must come from ExternalSecret'
  desc 'Ensure code-server password auth is backed by a Kubernetes Secret sourced from 1Password'

  helmrelease = FIRST_YAML.call(HELMRELEASE_PATH)
  env = helmrelease.dig('spec', 'values', 'controllers', 'code', 'containers', 'app', 'env')

  describe file(EXTERNALSECRET_PATH) do
    it { should exist }
    its('content') { should match(/name:\s+codeserver-auth/) }
    its('content') { should match(/key:\s+codeserver-auth/) }
    its('content') { should match(/secretKey:\s+PASSWORD/) }
  end

  describe env do
    it { should include('PASSWORD') }
  end

  describe env.dig('PASSWORD', 'valueFrom', 'secretKeyRef') do
    its(['name']) { should eq 'codeserver-auth' }
    its(['key']) { should eq 'PASSWORD' }
  end
end

control 'codeserver-oidc-forward-auth-route' do
  impact 1.0
  title 'CodeServer route must require oauth2-proxy'
  desc 'Ensure Traefik forward-auth is attached before traffic reaches CodeServer'

  httproute = FIRST_YAML.call(HTTPROUTE_PATH)
  filters = httproute.dig('spec', 'rules', 0, 'filters')
  backend_ref = httproute.dig('spec', 'rules', 0, 'backendRefs', 0)

  describe httproute.dig('spec', 'hostnames') do
    it { should include('code.ironstone.casa') }
  end

  describe filters do
    it { should include('type' => 'ExtensionRef', 'extensionRef' => { 'group' => 'traefik.io', 'kind' => 'Middleware', 'name' => 'oauth2-proxy-forward-auth' }) }
  end

  describe backend_ref do
    its(['name']) { should eq 'keda-add-ons-http-interceptor-proxy' }
    its(['namespace']) { should eq 'keda' }
    its(['port']) { should eq 8080 }
  end
end

control 'codeserver-keda-http-routing' do
  impact 1.0
  title 'CodeServer must route through KEDA HTTP add-on'
  desc 'Ensure InterceptorRoute and ReferenceGrant are present for HTTP request wake-up'

  interceptorroute = FIRST_YAML.call(INTERCEPTORROUTE_PATH)
  referencegrant = FIRST_YAML.call(REFERENCEGRANT_PATH)

  describe interceptorroute['apiVersion'] do
    it { should eq 'http.keda.sh/v1beta1' }
  end

  describe interceptorroute.dig('spec', 'target') do
    its(['service']) { should eq 'code' }
    its(['port']) { should eq 8080 }
  end

  describe interceptorroute.dig('spec', 'rules', 0, 'hosts') do
    it { should include('code.ironstone.casa') }
  end

  describe referencegrant['kind'] do
    it { should eq 'ReferenceGrant' }
  end

  describe referencegrant.dig('metadata', 'namespace') do
    it { should eq 'keda' }
  end

  describe referencegrant.dig('spec', 'from') do
    it { should include('group' => 'gateway.networking.k8s.io', 'kind' => 'HTTPRoute', 'namespace' => 'home-automation') }
  end
end

control 'codeserver-keda-schedule' do
  impact 1.0
  title 'CodeServer must scale during office hours and to zero when idle'
  desc 'Ensure KEDA combines HTTP request wake-up with Mon-Thu office-hours cron scaling'

  scaledobject = FIRST_YAML.call(SCALEDOBJECT_PATH)
  triggers = scaledobject.dig('spec', 'triggers')
  http_trigger = triggers.find { |trigger| trigger['type'] == 'external-push' }
  cron_trigger = triggers.find { |trigger| trigger['type'] == 'cron' }

  describe scaledobject.dig('spec', 'scaleTargetRef', 'name') do
    it { should eq 'code' }
  end

  describe scaledobject.dig('spec', 'minReplicaCount') do
    it { should eq 0 }
  end

  describe scaledobject.dig('spec', 'maxReplicaCount') do
    it { should eq 1 }
  end

  describe scaledobject.dig('spec', 'cooldownPeriod') do
    it { should eq 1800 }
  end

  describe http_trigger.dig('metadata', 'scalerAddress') do
    it { should eq 'keda-add-ons-http-external-scaler.keda:9090' }
  end

  describe http_trigger.dig('metadata', 'interceptorRoute') do
    it { should eq 'code' }
  end

  describe cron_trigger['metadata'] do
    its(['timezone']) { should eq 'Europe/London' }
    its(['start']) { should eq '0 9 * * 1-4' }
    its(['end']) { should eq '0 17 * * 1-4' }
    its(['desiredReplicas']) { should eq '1' }
  end
end
