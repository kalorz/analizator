#!/usr/bin/env ruby

require 'rubygems' # ruby1.9 doesn't 'require' it though
require 'thor'
require 'find'
require 'pathname'
require 'socket'
require 'yaml'
require 'request_log_analyzer'
require 'ftools'
require 'erb'

class MyOutput < RequestLogAnalyzer::Output::HTML

  def header
    super
    @io << tag(:p, "Blah!")
  end

  def footer
    @io << "</body></html>\n"
  end

end

class MyFilter < RequestLogAnalyzer::Filter::Field
    @@counter = 0
    
    def self.counter
      @@counter
    end

    def self.reset_counter
      @@counter = 0
    end

    # Keep request if @mode == :select and request has the field and value.
    # Drop request if @mode == :reject and request has the field and value.
    # Returns nil otherwise.
    # <tt>request</tt> Request Object
    def filter(request)
      found_field = request.every(@field).any? { |value| @value === value.to_s }
      @@counter +=1 if found_field
      return nil if !found_field && @mode == :select
      return nil if found_field && @mode == :reject
      return request
    end

end

class AdminAnalyzer < Thor
  LOG_FILES = 'log_files.yml'

  desc 'analyze', 'Prints 1, 2, 3'
  def analyze(root_path)
    raise ArgumentError.new('ROOT_PATH must be existing directory') unless File.directory?(root_path)

    # Resolve path
    root_path = Pathname.new(root_path).realpath.to_s

    puts "HOST: #{Socket.gethostname}"
    puts "ROOT: #{root_path}"

    log_files = File.exist?(LOG_FILES) ? YAML::load_file(LOG_FILES) : {}

    if log_files.any?
      puts "USING LOG FILES INDEX FROM #{LOG_FILES}"
    else
      log_files = {}
      
      Find.find(root_path) do |path|
        if FileTest.directory?(path)
          if File.basename(path)[0] == ?. # Does directory name start with a dot?
            Find.prune                    # Don't look any further into this directory.
          elsif File.exist?(File.join(path, 'config/environment.rb')) #&& # Detect Rails project
              #File.directory?(File.join(path, 'app/views/admin'))
            ['log/production.log', 'log/development.log'].each do |log|
              if File.exist?(File.join(path, log))
                log_file = Pathname.new(File.join(path, log)).realpath.to_s
                log_files[log_file] = log_files[log_file] == nil || log_files[log_file] == '' ? path : common_substring(path, log_files[log_file])
                print '.'
              end
            end
            Find.prune
          end
        end
      end

      File.open(LOG_FILES, 'w+') do |file|
        YAML.dump(log_files, file)
      end
    end

    Dir.mkdir('out') unless File.directory?('out')
    menu_html = '<html><head></head><body><ul>'

    i, size = 0, log_files.size
    log_files.each do |log_file, description|
      say "* [#{(i+=1).to_s.rjust(size.to_s.length)}/#{size}] #{log_file} (#{description})", :green
      MyFilter.reset_counter
      controller = RequestLogAnalyzer::Controller.build(:source_files => File.new(log_file), :output => MyOutput, :file => "out/#{i}.html", :silent => true)
      controller.add_filter(MyFilter, :mode => :select, :field => :controller, :value => /admin/i)
      controller.run!
      menu_html << %{<li><a href="#{i}.html" target="content">#{description}</a> (#{MyFilter.counter})</li>}
    end

    File.copy('index.html', 'out/index.html')

    menu_html << '</ul></body></html>'
    File.open('out/menu.html', 'w+') do |file|
      file.write(menu_html)
    end
  end

  def common_substring(*args)
    args.inject{|l,s| l=l.chop while l!=s[0...l.length];l}
  end

end

AdminAnalyzer.start