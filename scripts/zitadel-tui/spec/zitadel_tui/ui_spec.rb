# frozen_string_literal: true

require 'spec_helper'

RSpec.describe ZitadelTui::UI do
  subject(:ui) { described_class.new }

  describe '#initialize' do
    it 'creates a pastel instance' do
      expect(ui.pastel).to be_a(Pastel::Delegator)
    end

    it 'creates a prompt instance' do
      expect(ui.prompt).to be_a(TTY::Prompt)
    end

    it 'creates a logger instance' do
      expect(ui.logger).to be_a(TTY::Logger)
    end
  end

  describe '#success' do
    it 'outputs a success message' do
      expect { ui.success('test') }.to output(/test/).to_stdout
    end
  end

  describe '#error' do
    it 'outputs an error message' do
      expect { ui.error('test') }.to output(/test/).to_stdout
    end
  end

  describe '#info' do
    it 'outputs an info message' do
      expect { ui.info('test') }.to output(/test/).to_stdout
    end
  end

  describe '#warning' do
    it 'outputs a warning message' do
      expect { ui.warning('test') }.to output(/test/).to_stdout
    end
  end
end
