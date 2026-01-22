# frozen_string_literal: true

require 'tty-prompt'
require 'tty-box'
require 'tty-table'
require 'tty-spinner'
require 'tty-logger'
require 'pastel'

module ZitadelTui
  class UI
    attr_reader :prompt, :pastel, :logger

    def initialize
      @pastel = Pastel.new
      @prompt = TTY::Prompt.new(
        active_color: :cyan,
        help_color: :bright_black,
        symbols: { marker: '▸' }
      )
      @logger = TTY::Logger.new do |config|
        config.level = :info
      end
    end

    def header(title)
      box = TTY::Box.frame(
        title.center(50),
        padding: [0, 2],
        border: :thick,
        style: {
          fg: :bright_cyan,
          border: { fg: :cyan }
        }
      )
      puts "\n#{box}\n"
    end

    def subheader(text)
      puts pastel.bright_blue.bold("\n═══ #{text} ═══\n")
    end

    def success(message)
      puts pastel.green("✓ #{message}")
    end

    def error(message)
      puts pastel.red("✗ #{message}")
    end

    def warning(message)
      puts pastel.yellow("⚠ #{message}")
    end

    def info(message)
      puts pastel.cyan("ℹ #{message}")
    end

    def divider
      puts pastel.bright_black('─' * 60)
    end

    def newline
      puts
    end

    def spinner(message, &block)
      spinner = TTY::Spinner.new(
        "[:spinner] #{message}",
        format: :dots,
        success_mark: pastel.green('✓'),
        error_mark: pastel.red('✗')
      )
      spinner.auto_spin

      begin
        result = block.call
        spinner.success(pastel.green('Done'))
        result
      rescue StandardError => e
        spinner.error(pastel.red('Failed'))
        raise e
      end
    end

    def table(headers, rows, **options)
      table = TTY::Table.new(
        header: headers.map { |h| pastel.bright_cyan.bold(h) },
        rows: rows
      )
      puts table.render(:unicode, padding: [0, 1], **options)
    end

    def box(content, **options)
      defaults = {
        padding: [0, 1],
        border: :round,
        style: { border: { fg: :bright_black } }
      }
      puts TTY::Box.frame(content, **defaults, **options)
    end

    def credentials_box(title, credentials)
      content = credentials.map { |k, v| "#{pastel.bright_white(k)}: #{pastel.yellow(v)}" }.join("\n")

      box = TTY::Box.frame(
        content,
        title: { top_left: " #{title} " },
        padding: [0, 1],
        border: :round,
        style: {
          fg: :white,
          border: { fg: :green }
        }
      )
      puts box
    end

    def select_menu(question, choices, **options)
      defaults = {
        cycle: true,
        per_page: 10,
        show_help: :always,
        filter: true
      }
      prompt.select(question, choices, **defaults, **options)
    end

    def multi_select_menu(question, choices, **options)
      defaults = {
        cycle: true,
        per_page: 10,
        show_help: :always,
        filter: true,
        min: 1
      }
      prompt.multi_select(question, choices, **defaults, **options)
    end

    def ask(question, **options)
      prompt.ask(question, **options)
    end

    def yes?(question, **options)
      prompt.yes?(question, **options)
    end

    def mask(question, **options)
      prompt.mask(question, **options)
    end

    def collect(&)
      prompt.collect(&)
    end

    def clear
      print "\e[2J\e[H"
    end

    def press_any_key
      prompt.keypress(pastel.bright_black("\nPress any key to continue..."))
    end
  end
end
