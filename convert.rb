#!/usr/bin/env ruby

# require some built-in ruby libraries
require 'optparse'
require 'cgi'

# require some rubygems
require 'rubygems'
require 'hpricot'
require 'chronic'

class ScarabParser
  def self.parse(filename)
    # return value is an empty hash to start with
    issues =  {}
    
    # open the input file and start processing
    (Hpricot(open(filename))/"scarab-issues issues issue").each do |issue|
      # start a new hash for this issue
      issue_hash = issues[(issue/"> id").inner_html] = {}
      
      # sort the activity on this issue by creation date (creation date of the activity)
      sets = (issue/"activity-sets activity-set").sort do |a, b|
        a_time = Chronic.parse((a/"created-date timestamp").inner_html)
        b_time = Chronic.parse((b/"created-date timestamp").inner_html)
        a_time.to_i <=> b_time.to_i
      end
      
      # go through each set updating the relevant attribute for the issue (so that we arrive
      # at the latest timestamped values since the sets are now sorted)
      sets.each do |set|
        (set/"activities activity").each do |activity|
          unless (name = (activity/"attribute name")).nil? || name.inner_html =~ /^null/i
            issue_hash[name.inner_html] = CGI::unescapeHTML((activity/"new-value").inner_html)
            issue_hash[name.inner_html].gsub! /"/, '""'
          end
        end
      end
    end

    issues
  end
end

# main class of this application
class App
  VERSION    = '1.0'
  COMMAND    = File.basename(__FILE__)
  STATUS_MAP = {
    'Submitted'           => 'unscheduled',
    'Developer Submitted' => 'unscheduled',
    'SMEs Need Clarity'   => 'unscheduled',
    'Need Clarity'        => 'unscheduled',
    'Clarified'           => 'unstarted',
    'UAT Specified'       => 'unstarted',
    'In Development'      => 'started',
    'Developed'           => 'finished',
    'Likely Slipping'     => 'started',
    'Estimate Requested'  => 'unscheduled',
    'Tested'              => 'delivered',
    'Deployed'            => 'accepted',
    'Torn Up'             => 'unscheduled'
  }

  # initializer method
  def initialize
    # default options
    @options = {
      :out        => nil,
      :story_type => 'feature'
    }
  end
  
  # parse command line options and required parameters
  def options_parse
    # first, deal with all options
    opts = OptionParser.new do |opts|
      opts.banner  = "Usage: #{COMMAND} [options] <cn_tracker_export>\n"
      opts.banner += "Convert CollabNet project tracker artifacts to Pivotal Tracker format"

      opts.on("-h", "Show this message") do
        puts opts
        exit
      end

      opts.on("-v", "Display this application's version and exit") do
        puts "#{COMMAND} version #{VERSION}"
        exit
      end
            
      opts.on("-o <filename>", "Direct output to <filename> rather than the console") do |filename|
        if File.exists?(filename) && (!File.writable?(filename) || File.directory?(filename))
          puts "Specified filename '#{filename}' is not writable\n\n#{opts}"
          exit
        elsif !File.exists?(filename) && !File.writable?(File.dirname(filename))
          puts "Location of specified filename '#{filename}' is not writable\n\n#{opts}"
          exit
        end
        
        @options[:out] = filename
      end
      
      opts.on("-t < feature | chore | bug >", "The type of story to generate") do |type|
        unless [ 'feature', 'chore', 'bug' ].include?(type)
          puts "Type '#{type}' is invalid.  Only 'feature', 'chore', or 'bug' are allowed."
          puts "\n#{opts}"
          exit
        end
        @options[:story_type] = type
      end
    end
    
    # try parsing options, rescuing certain errors and printing friendly messages
    begin
      opts.parse!
    rescue OptionParser::InvalidOption => e
      puts "#{e}\n\n#{opts}"
      exit
    end
    
    # now, make sure that there are enough arguments left for required parameters
    case
    when ARGV.length < 1
      puts "You must specify a CollabNet project tracker export (<cn_tracker_export>)\n\n#{opts}"
      exit
    when !File.exists?(ARGV[0])
      puts "Specified input file '#{ARGV[0]}' does not exist\n\n#{opts}"
      exit
    when !File.readable?(ARGV[0])
      puts "Specified input file '#{ARGV[0]}' is not readable\n\n#{opts}"
      exit
    when File.directory?(ARGV[0])
      puts "Specified input file '#{ARGV[0]}' is a directory, not a file\n\n#{opts}"
      exit
    end
   
    @options[:in] = ARGV[0]
  end
    
  # "main" method for this application
  def run
    options_parse
    
    # output files (or set outfile to $stdout if no output file specified)
    outfile = $stdout
    unless @options[:out].nil?
      outfile = File.open(@options[:out], "w+")
    end
    
    outfile.write "Id,Story,Labels,Iteration,Iteration Start,Iteration End,Story Type,Estimate,"
    outfile.write "Current State,Created at,Accepted at,Deadline,Requested By,Owned By,"
    outfile.puts  "Description,URL,Note"
    id = 1
    
    # parse the input file and produce 
    ScarabParser.parse(@options[:in]).each do |key, attributes|
      # provide estimates for the statuses that require them
      new_status = STATUS_MAP[attributes["Status"]]
      estimate = case
        when [ 'finished', 'accepted', 'started' ].include?(new_status) then
          case (attributes["Estimated effort"] || 1).to_i
          when 0      then 0
          when 1      then 1
          when 2..6   then 2
          when 7..12  then 3
          when 13..24 then 5
          else 8
          end
        else ''
        end
        
      # build the CSV row for the new input file
      outfile.write(id)                                             # Id
      outfile.write(",\"#{attributes["Summary"]}\"")                # Story
      outfile.write(",")                                            # Labels
      outfile.write(",")                                            # Iteration
      outfile.write(",")                                            # Iteration Start
      outfile.write(",")                                            # Iteration End
      outfile.write(",#{@options[:story_type]}")                    # Story Type
      outfile.write(",#{estimate}")                                 # Estimate
      outfile.write(",#{new_status}")                               # Current State
      outfile.write(",")                                            # Created at
      outfile.write(",")                                            # Accepted at
      outfile.write(",")                                            # Deadline
      outfile.write(",")                                            # Requested By
      outfile.write(",")                                            # Owned By
      outfile.write(",\"#{attributes["Description"]}\"")            # Description
      outfile.write(",")                                            # URL
      outfile.write(",")                                            # Note
      outfile.write("\n")
      
      # increment ID for the next pass
      id += 1
    end
    
    # close output file (if one was opened)
    unless @options[:out].nil?
      outfile.close
    end
  end
end

# run the application
App.new.run
