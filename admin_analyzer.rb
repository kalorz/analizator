#!/usr/bin/env ruby

require 'rubygems' # ruby1.9 doesn't 'require' it though
require 'thor'
require 'find'
require 'pathname'
require 'socket'
require 'yaml'
require 'request_log_analyzer'
require 'fileutils'

class Progress
  module Ansi
    CR    = "\r"
    CLEAR = "\e[0K"
    RESET = CR + CLEAR
  end

  SPINNER    = %w(| / - \\)
  ANIM_SPEED = 0.1

  def initialize
    @cycle, @anim_cycle, @last_tick = 0, 0, Time.now
  end

  def tick(message = nil)
    unless Time.now - @last_tick < ANIM_SPEED
      @anim_cycle += 1
      @last_tick   = Time.now
    end

    @message = message unless message.nil? || message == ''

    print "#{Ansi::RESET}[#{SPINNER[@anim_cycle % SPINNER.size]}] #{@message}"
    $stdout.flush

    @cycle += 1
  end

end

class MyOutput < RequestLogAnalyzer::Output::HTML

  def footer
    @io << "</body></html>\n"
  end

end

class AdminAnalyzer < Thor
  LOG_FILES = 'log_profiles.yml'

  desc 'analyze', 'Analyzes all log files in given directory'
  def analyze(root_path)
    raise ArgumentError.new('ROOT_PATH must be existing directory') unless File.directory?(root_path)

    # Resolve path
    root_path = Pathname.new(root_path).realpath.to_s

    host = Socket.gethostname
    profile = "#{root_path}@#{host}"

    puts "HOST: #{host}"
    puts "ROOT: #{root_path}"

    log_profiles = File.exist?(LOG_FILES) ? YAML::load_file(LOG_FILES) : {}
    logs = {}

    if log_profiles[profile]
      puts "USING LOG FILES INDEX FROM #{LOG_FILES}"
      logs = log_profiles[profile]
    else
      logs = []

      find_log_files(logs, root_path, Progress.new)
      puts ''

      log_profiles[profile] = logs

      File.open(LOG_FILES, 'w+') do |file|
        YAML.dump(log_profiles, file)
      end
    end

    Dir.mkdir('out') unless File.directory?('out')
    menu_html = '<html><head></head><body><ul>'

    i, size = 0, logs.size
    logs.each do |log|
      say "* [#{(i+=1).to_s.rjust(size.to_s.length)}/#{size}] #{log}", :green
      controller = RequestLogAnalyzer::Controller.build(
          :source_files => log,
          :output       => MyOutput,
          :select       => {:controller => /admin/i},
          :file         => "out/#{i}.html",
          :silent       => true
      )
      controller.run!
      menu_html << %{<li><a href="#{i}.html" target="content" title="#{log}">#{guess_project_name(log, root_path)}</a> <span title="#{guess_project_environment(log)}">[#{guess_project_environment(log)[0..0].upcase}]</span> <span title="Proper requests">(#{controller.source.parsed_requests - controller.source.skipped_requests})</span></li>}
    end

    FileUtils.cp('index.html', 'out/index.html')

    menu_html << '</ul></body></html>'
    File.open('out/menu.html', 'w+') do |file|
      file.write(menu_html)
    end
  end

  private ##############################################################################################################

  def find_log_files(out, root_path, progress = nil, depth = 0)
    Find.find(root_path) do |path|
      progress.tick if progress
      if FileTest.directory?(path)
        if File.basename(path)[0] == ?. # Does directory name start with a dot?
          Find.prune                    # Don't look any further into this directory.
        elsif FileTest.symlink?(path) && depth < 100 # Prevent deadlock
          find_log_files(out, File.readlink(path), progress, depth + 1)
        elsif File.exist?(File.join(path, 'config/environment.rb')) # Detect Rails project
          ['log/production.log', 'log/development.log'].each do |log|
            if File.exist?(File.join(path, log))
              log = Pathname.new(File.join(path, log)).realpath.to_s
              out << log unless out.include?(log)
              progress.tick(log) if progress
            end
          end
          Find.prune
        end
      end
    end
  end

  def guess_project_name(log, root_path)
    log.gsub!(Regexp.new("^#{Regexp.escape(root_path)}\/?"), '')
    if log.match(/([^\/]+)(\/shared|\/current|\/releases)?\/log/)
      "#{$1}"
    else
      log.gsub(/\/log\/.+\.log$/, '')
    end
  end

  def guess_project_environment(log)
    if log.match(/\/log\/(.+)\.log$/)
      "#{$1}"
    else
      '?'
    end
  end

end

AdminAnalyzer.start
