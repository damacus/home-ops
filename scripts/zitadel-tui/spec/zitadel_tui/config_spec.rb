# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ZitadelTui::Config do
  subject(:config) { described_class.new }

  describe '#zitadel_url' do
    it 'returns the default URL' do
      expect(config.zitadel_url).to eq('https://zitadel.damacus.io')
    end
  end

  describe '#onepassword_vault' do
    it 'returns the default vault' do
      expect(config.onepassword_vault).to eq('home-ops')
    end
  end

  describe '#sa_key_file' do
    it 'returns the default key file path' do
      expect(config.sa_key_file).to eq('/tmp/zitadel-sa.json')
    end
  end
end
