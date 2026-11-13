#!/usr/bin/env ruby
# frozen_string_literal: true

require_relative '../lib/home_ops/provisioning/app'

exit HomeOps::Provisioning::App.cli(ARGV)
