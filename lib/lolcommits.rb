$:.unshift File.expand_path('.')

require "lolcommits/version"
require "tranzlate/lolspeak"
require "choice"
require "fileutils"
require "git"
require "RMagick"
require "open3"
require "launchy"
require 'yaml'
require 'twitter'
require 'oauth'
include Magick

TWITTER_CONSUMER_KEY = 'qc096dJJCxIiqDNUqEsqQ'
TWITTER_CONSUMER_SECRET = 'rvjNdtwSr1H0TvBvjpk6c4bvrNydHmmbvv7gXZQI'


module Lolcommits
  $home = ENV['HOME']
  LOLBASEDIR = File.join $home, ".lolcommits"
  LOLCOMMITS_ROOT = File.join(File.dirname(__FILE__), '..')

  def is_mac?
    RUBY_PLATFORM.downcase.include?("darwin")
  end

  def is_linux?
    RUBY_PLATFORM.downcase.include?("linux")
  end

  def is_windows?
    if RUBY_PLATFORM =~ /(win|w)32$/
      true
    end
  end

  def most_recent(dir='.')
    loldir, commit_sha, commit_msg = parse_git
    Dir.glob(File.join loldir, "*").max_by {|f| File.mtime(f)}
  end
  
  def loldir(dir='.')
    loldir, commit_sha, commit_msg = parse_git
    return loldir
  end
  
  def parse_git(dir='.')
    g = Git.open('.')
    commit = g.log.first
    commit_msg = commit.message.split("\n").first
    commit_sha = commit.sha[0..10]
    basename = File.basename(g.dir.to_s)
    basename.sub!(/^\./, 'dot') #no invisible directories in output, thanks!
    loldir = File.join LOLBASEDIR, basename
    return loldir, commit_sha, commit_msg
  end

  def github_remotes(dir='.')
    g = Git.open('.')
    remotes = g.remotes.map { |remote| URI.parse(remote.url) }
    github_remotes = remotes.select { |uri| uri.host =~ /\.?github.com$/ }

    return (github_remotes.length > 0 ? github_remotes : nil)
  end

  def capture(capture_delay=0, is_test=false, test_msg=nil, test_sha=nil, do_twitter=nil)
    #
    # Read the git repo information from the current working directory
    #
    if not is_test
      loldir, commit_sha, commit_msg = parse_git
    else
      commit_msg = test_msg
      commit_sha = test_sha
      loldir = File.join LOLBASEDIR, "test"
    end
    
    #
    # lolspeak translate the message
    #
    if (ENV['LOLCOMMITS_TRANZLATE'] == '1' || false)
        commit_msg = commit_msg.tranzlate
    end

    #
    # Create a directory to hold the lolimages
    #
    if not File.directory? loldir
      FileUtils.mkdir_p loldir
    end

    #
    # SMILE FOR THE CAMERA! 3...2...1...
    # We're just assuming the captured image is 640x480 for now, we may
    # need updates to the imagesnap program to manually set this (or resize)
    # if this changes on future mac isights.
    #
    puts "*** Preserving this moment in history."
    snapshot_loc = File.join loldir, "tmp_snapshot.jpg"
    if is_mac?
      imagesnap_bin = File.join LOLCOMMITS_ROOT, "ext", "imagesnap", "imagesnap"
      system("#{imagesnap_bin} -q #{snapshot_loc} -w #{capture_delay}")
    elsif is_linux?
      tmpdir = File.expand_path "#{loldir}/tmpdir#{rand(1000)}/"
      FileUtils.mkdir_p( tmpdir )
      # There's no way to give a capture delay in mplayer, but a number of frame
      # I've found that 6 is a good value for me.
      frames = if capture_delay != 0 then capture_delay else 6 end

      # mplayer's output is ugly and useless, let's throw it away
      _, r, _ = Open3.popen3("mplayer -vo jpeg:outdir=#{tmpdir} -frames #{frames} tv://")
      # looks like we still need to read the output for something to happen
      r.read
      FileUtils.mv(tmpdir + "/%08d.jpg" % frames, snapshot_loc)
      FileUtils.rm_rf( tmpdir )
    elsif is_windows?
      commandcam_exe = File.join LOLCOMMITS_ROOT, "ext", "CommandCam", "CommandCam.exe"
      # DirectShow takes a while to show... at least for me anyway
      delaycmd = " /delay 3000"
      if capture_delay > 0
        # CommandCam delay is in milliseconds
        delaycmd = " /delay #{capture_delay * 1000}"
      end
      _, r, _ = Open3.popen3("#{commandcam_exe} /filename #{snapshot_loc}#{delaycmd}")
      # looks like we still need to read the output for something to happen
      r.read
    end


    #
    # Process the image with ImageMagick to add loltext
    #

    # read in the image, and resize it via the canvas
    canvas = ImageList.new("#{snapshot_loc}")
    if (canvas.columns > 640 || canvas.rows > 480)
      canvas.resize_to_fill!(640,480)
    end

    # create a draw object for annotation
    draw = Magick::Draw.new
    #if is_mac?
    #  draw.font = "/Library/Fonts/Impact.ttf"
    #else
    #  draw.font = "/usr/share/fonts/TTF/impact.ttf"
    #end
    draw.font = File.join(LOLCOMMITS_ROOT, "fonts", "Impact.ttf")

    draw.fill = 'white'
    draw.stroke = 'black'

    # convenience method for word wrapping
    # based on https://github.com/cmdrkeene/memegen/blob/master/lib/meme_generator.rb
    def word_wrap(text, col = 27)
      wrapped = text.gsub(/(.{1,#{col + 4}})(\s+|\Z)/, "\\1\n")
      wrapped.chomp!
    end

    draw.annotate(canvas, 0, 0, 0, 0, commit_sha) do
      self.gravity = NorthEastGravity
      self.pointsize = 32
      self.stroke_width = 2
    end

    draw.annotate(canvas, 0, 0, 0, 0, word_wrap(commit_msg)) do
      self.gravity = SouthWestGravity
      self.pointsize = 48
      self.interline_spacing = -(48 / 5) if self.respond_to?(:interline_spacing)
      self.stroke_width = 2
    end

    #
    # Squash the images and write the files
    #
    #canvas.flatten_images.write("#{loldir}/#{commit_sha}.jpg")
    canvas.write(File.join loldir, "#{commit_sha}.jpg")
    FileUtils.rm(snapshot_loc)

    # post to twitter!
    unless do_twitter.nil?
      post_to_twitter(File.join(loldir,"#{commit_sha}.jpg"), commit_msg, loldir)
    end

    #if in test mode, open image for inspection
    if is_test
      Launchy.open(File.join loldir, "#{commit_sha}.jpg")
    end
  end

  def post_to_twitter(file, commit_msg, loldir)
    g = Git.open('.')
    current_branch = g.branch.name
    tracked_remote = g.config["branch.#{current_branch}.remote"]
    if tracked_remote
      remote = g.remotes.select { |remote| remote.name == tracked_remote }.first.url
      remote = URI.parse(remote)
      if github_remotes.include?(remote)
        github_repo = remote.path.sub(/.git$/, '')
        commit_sha = parse_git[1]
        commit_url = 'https://github.com' + github_repo + '/commit/' + commit_sha
      end
    end

    # build tweet text
    available_commit_msg_size = 128 
    tweet_msg = commit_msg.length > available_commit_msg_size ? "#{commit_msg[0..(available_commit_msg_size-3)]}..." : commit_msg
    tweet_text = ""
    tweet_text << tweet_msg
    if commit_url
      tweet_text << " " + commit_url + " "
    end
    tweet_text << " #lolcommits"
    puts "Tweeting: #{tweet_text}"

    # if this the first time w/r/t oauth?
    if !File.exists?(File.join(loldir, "..", ".tw_auth"))
      initial_twitter_auth(loldir)
    end

    if File.exists?(File.join(loldir, "..", ".tw_auth"))
      creds = YAML.load_file(File.join(loldir, "..", ".tw_auth"))
      Twitter.configure do |config|
        config.consumer_key = TWITTER_CONSUMER_KEY
        config.consumer_secret = TWITTER_CONSUMER_SECRET
      end
      client = Twitter::Client.new(
        :oauth_token => creds[:access_token],
        :oauth_token_secret => creds[:secret]
      )
      retries = 2
      begin
        if client.update_with_media(tweet_text, File.open(file, 'r'))
          puts "Tweet Sent!"
        end
      rescue Twitter::Error::InternalServerError
        retries -= 1
        retry if retries > 0
        puts "Tweet 500 Error - Tweet Not Posted"
      end
    else
      puts "Tweet Not Sent - No Credentials"
    end
  end

  def initial_twitter_auth(loldir)
    puts "\n--------------------------------------------"
    puts "Need to grab twitter tokens (first time only)"
    puts "---------------------------------------------"

    consumer = OAuth::Consumer.new(TWITTER_CONSUMER_KEY, 
                                   TWITTER_CONSUMER_SECRET,
                                   :site => 'http://api.twitter.com',
                                   :request_endpoint => 'http://api.twitter.com',
                                   :sign_in => true)

    request_token = consumer.get_request_token
    rtoken  = request_token.token
    rsecret = request_token.secret

    puts "\n1.) Open the following url in your browser, get the PIN:\n\n"
    puts request_token.authorize_url
    puts "\n2.) Enter PIN, then press enter:"

    begin
      STDOUT.flush
      twitter_pin = STDIN.gets.chomp
    rescue
    end

    if (twitter_pin.nil?) || (twitter_pin.length == 0)
      puts "\n\tERROR: Could not read PIN, auth fail"
      return
    end

    begin
      OAuth::RequestToken.new(consumer, rtoken, rsecret)
      access_token = request_token.get_access_token(:oauth_verifier => twitter_pin)
    rescue Twitter::Unauthorized
      puts "> FAIL!"
    end

    creds = {:access_token => access_token.token,
             :secret => access_token.secret}

    begin
      f = File.open(File.join(loldir, "..", ".tw_auth"), "w")
      f.write creds.to_yaml
      f.close
    rescue
      puts "\n\tERROR: could not write credentials to: #{File.join(loldir, "..", ".tw_auth")}"
      return
    end
  end
end
