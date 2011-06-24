---
title: Plugins in Ruby
now: Fri Jun 24 09:13:59 2011
---

Plugins are often useful to allow the user to extend features of a
program. Providing a nice plugin API is not so obvious yet — the user of this
code is supposed to be able to extend the program, he doesn't want to just
monkey patch a bunch of classes and hope it will still work. To allow the user
to do something useful, the program should have a module architecture, so that
it would be able to work.

Let's just list several ideas to make this incredibly powerful program
extensible:

    while line = gets
      puts line
    end
{:.ruby}

Finding the plugins
-------------------

Obvioulsy, once we have our program, the first step is to find a plugin.

### Using a config file

You could just let use a config file to list the extensions to load, and simply
require the files that are mentioned:

    require 'yaml'

    open("config.yaml") { |io| YAML.load(io) }.each do |file|
      begin
        require file
      rescue LoadError
        $stderr.puts "WARNING: plugin #{file} could not be loaded!"
      end
    end
{:.ruby}

The benefit of this is you can specify what plugins need to be loaded; this also
means a plugin won't be found automatically.

### Using Gem

Rubygems can be helpful to find plugins. By assuming all plugins are installed
through gems with a name starting by your prefix, and that the file to require
has the same name as the gem, you can use ``Gem::Specification`` to find them:

    require 'rubygems'

    Gem::Specification.each do |gem|
      if gem.name.start_with? "genious-printer-"
        begin
          require gem.name
        rescue LoadError
          $stderr.puts "WARNING: plugin #{gem.name} could not be loaded!"
        end
      end
    end
{:.ruby}

This allows you to find any plugin easily, but, when implemented as above, it
doesn't allow to blacklist plugins; you would have to still use a config file
for this. Let's use this here, so we can default to use all the available
plugins. :)

Loading a backend
-----------------

One way to make plugins interact with your program is to make them be a
backend. Then, your program will drive the execution flow and the plugin
will do the basic work. This can be useful to completely change the behaviour of
the program, but also means only one plugin can do it. Still, let's write a such
plugin… to… write every "e" in red and add a timestamp!

    require 'rubygems'

    class GeniousPrinter
      class Backend
        def gets
          $stdin.gets
        end

        def puts(line)
          $stdout.puts line
        end
      end

      class << self
        attr_accessor :backend

        def run
          new(backend).run
        end
      end

      @backend = Backend.new

      def initialize(backend)
        @backend = backend
      end

      def run
        while line = @backend.gets
          @backend.puts line
        end
      end
    end

    # Load plugins here
    Gem::Specification.each do |gem|
      if gem.name.start_with? "genious-printer-"
        begin
          require gem.name
        rescue LoadError
          $stderr.puts "WARNING: plugin #{gem.name} could not be loaded!"
        end
      end
    end

    GeniousPrinter.run
{:.ruby}

    class GeniousBackend
      def gets
        if line = $stdin.gets
          line.gsub("e", "\e[31me\e[0m")
        end
      end

      def puts(line)
        $stdout.puts "[#{Time.now.strftime "%T"}] #{line}"
      end
    end

    GeniousPrinter.backend = GeniousBackend.new
{:.ruby}

Here's a sample session *without* our plugin:

    hello
    hello
    this is a test
    this is a test
    this is incredibly useful!
    this is incredibly useful!
{:.term}

But here's a session *with* our plugin! (imagine every single "e" is actually
red!)

    hello
    [10:17:19] hello
    this is a test
    [10:17:22] this is a test
    this is incredibly useful
    [10:17:26] this is incredibly useful
{:.term}

Now, clearly, this makes our program way more powerful and useful.

Hook-based plugins
------------------

This current plugin system isn't powerful enough. What if we want to log what
the user types, for instance? If we do this with a backend, other plugins will
not work. So, we should have a way to notify any plugins that want to know about
something. We can do this with a hook: by registering something to do (say,
calling a block) when an event occurs.

    class GeniousPrinter
      @hooks = Hash.new { |h, k| h[k] = [] }

      def self.on(event, &block)
        @hooks[event] << block
      end

      def self.fire!(event, *args)
        @hooks[event].each { |hook| hook.call(*args) }
      end

      def run
        GeniousPrinter.fire! :start

        while line = @backend.gets
          GeniousPrinter.fire! :input, line
          @backend.puts line
        end

        GeniousPrinter.fire! :end
      end
    end
{:.ruby}

    io = nil

    GeniousPrinter.on :start do
      io = open(File.join(ENV["HOME"], ".genious_print_log"), "w")
      io.puts "session started"
    en

    GeniousPrinter.on :input do |line|
      io.puts line
    end

    GeniousPrinter.on :end do
      io.puts "session ended"
      io.close
    end
{:.ruby}

And now we can get our logs, just in case we would want to read them again
(again, don't forget those "e"s are actually red)!

    session started
    hello
    this is a test
    this is incredibly useful!
    session ended
{:.term}
