# frozen_string_literal: true

require "bridgetown"
Bridgetown.load_tasks

task default: :deploy

desc "Build documentation for GitHub Pages"
task deploy: [:clean, "frontend:build"] do
  Bridgetown::Commands::Build.start
end

desc "Remove generated documentation"
task :clean do
  Bridgetown::Commands::Clean.start
end

namespace :frontend do
  task :build do
    sh "npm run esbuild"
  end
  task :dev do
    sh "npm run esbuild-dev"
  end
end
