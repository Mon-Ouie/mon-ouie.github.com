---
title: Rubinius Debugging API
now: Mon Jun 20 21:12:17 2011
---

Most Ruby implementations provide an API to write a debugger, if not a debugger
itself. MRI has a tracer API, also implemented by JRuby:

    set_trace_func proc { |event, *other_stuff|
      # do stuff
    }
{:.ruby}

This allows to trace whatever happens, and to stop the process to debug it. One
can implement a debugger with this, for instance as debug.rb from stdlib
does. Rubinius, however does not implement a such API. But Rubinius being all
Ruby, one can probably write a such thing — or a better way one — just in Ruby
:)

It is indeed posible to write a debugger for Rubinius in Ruby. Rubinius even
comes with one that introduces itself as a sample to show how to write a
debugger:

    #
    # The Rubinius reference debugger.
    #
    # This debugger is wired into the debugging APIs provided by Rubinius.
    # It serves as a simple, builtin debugger that others can use as
    # an example for how to build a better debugger.
    #

    class Rubinius::Debugger
      # Code is here :)
    end
{:.ruby}

I'm probably not good at this, but it's quite hard for me to figure out how this
works, so I write about it so I can share my knowledge with the world… and
understand the code I will write using this knowledge. :)

A simple debugger
-----------------

I will try to reduce the Rubinius debugger to the simplest code that works, so
that it can easily be used as a template. At the end of this section, the
debugger will not really be useful. So let's only keep a block in our Debugger
object. This block will be called when a breakpoint is reached.

    class Debugger
      def initialize(&block)
        @block = block
      end
    end
{:.ruby}

Now that we have this *very* useful class, let's add some more features to it!
Rubinius uses another thread for debugging. Using one of Rubinius' classes
(``Rubinius::Channel``), this thread will be fed with information about the
debugged program. ``Debugger#listen`` will just be a loop that waits for a
breakpoint to be reached before calling our block.


    def spawn_thread
      return if @thread

      @local_channel = Rubinius::Channel.new

      @thread = Thread.new do
        begin
          listen
        rescue Exception => ex # avoid silent fails
          $stdout.puts "#{ex.class}: #{ex}"
        end
      end

      # This tells Rubinius what channel to use to send information about the
      # debugged program.
      @thread.setup_control! @local_channel
    end
    private :spawn_thread

    def listen
      loop do
        # Get information.
        # Rubinius will send us 4 objects:
        #   1. A breakpoint: an aribtrary object which we can set.
        #   2. The thread where the event occurred
        #   3. The Rubinius::Channel that sent the event
        #   4. The backtrace, as an array of Rubinius::Location objects
        bp, thread, chan, locs = @local_channel.receive

        # Call our block (which does not care about the channel)!
        @block.call bp, thread, locs

        # Tell the channel we are done with it
        chan << true
      end
    end
{:.ruby}

Now, we are about to be able to start our debugger. To achieve this, we will
need a breakpoint class — but let's just make it an empty class for now.


    class Breakpoint
      def initialize(method, line)
        # There will be code here!
      end
    end
{:.ruby}

When starting the debugger we must first, of course, spawn our debugging thread,
and then send information to it. Then we will set the debugger thread of the
current thread to the thread we created.

    def start
      # Spawn debugging thread if needed.
      spawn_thread

      # Get the backtrace.
      locs    = Rubinius::VM.backtrace(1, true)

      # Get a CompiledMethod object to create our breakpoint.method
      method  = Rubinius::CompiledMethod.of_sender
      bp      = Breakpoint.new(method, locs.first.line)

      # Create a channel to communicate with our thread.
      channel = Rubinius::Channel.new

      # Send our objects
      @local_channel.send Rubinius::Tuple[bp, Thread.current, channel, locs]

      # Wait that the thread is done
      channel.receive

      # Set the debugger thread.
      Thread.current.set_debugger_thread @thread
    end
{:.ruby}

Now we can try this code, and see that our callback gets called! :)

    dbg = Debugger.new do |bp, thread, locs|
      loc = locs.first
      puts "Reached breakpoint at #{loc.file}:#{loc.line}"
    end

    dbg.start
{:.ruby}

And we get the expected output (with probably another line number):

    Reached breakpoint at debugger.rb:100
{:.term}

Adding breakpoints
------------------

A debugger is only useful when it can stop execution at some point. Of course we
don't have to send debugging information to the debugger ourselves — or this
wouldn't be a debugging API… — and we can use Rubinius'
``CompiledMethod#set_breakpoint`` to tell Rubinius "I want you to tell my
debugger thread when this line is reached; also, give it a reference to
me.". Let's try this!

    class Breakpoint
      def initialize(method, line)
        # Call method.executable if an UnboundMethod or a Method is passed.
        @method = case method
                  when Rubinius::Executable then method
                  else method.executable
                  end

        # Get ip of the line (used to set and remove the breakpoint)
        # (line is relative to the beginning of the file, not to the method)
        @ip = @method.first_ip_on_line(line)
      end

      def enable
        # Set the breakpoint of that line to ourselves
        @method.set_breakpoint @ip, self
      end

      def disable
        # Remove the breakpoint on that line
        @method.clear_breakpoint @ip
      end
    end
{:.ruby}

And now, we can try to see if our callback gets called!

    class Foo
      def initialize(x)
        @x = x
      end
    end

    Breakpoint.new(Foo.instance_method(:initialize), __LINE__ - 4).enable

    Foo.new 10
{:.ruby}

The result should still be what you expect:

    Reached breakpoint at debugger.rb:96
{:.term}

Getting a binding object
------------------------

Binding objects can be very useful in a debugger: when you get a binding from
the debugged program, you can run arbitrary code in its context to get any
information you may want about it.

We don't have a binding object now, but that won't stop us! We have location
objects, which can be used to get a such binding as needed.

    class Frame
      def initialize(loc)
        @loc = loc
      end

      attr_reader :loc

      def run(code)
        eval(code, binding)
      end

      def binding
        @binding ||= Binding.setup(@loc.variables,
                                   @loc.methods,
                                   @loc.static_scope)
      end
    end
{:.ruby}

You can try to print, for instance, what instance variables are defined at that
point:

    dbg = Debugger.new do |bp, thread, locs|
      frame = Debugger::Frame.new(locs.first)
      puts "Instance variables: #{fram.run('instance_variables').inspect}"
    end

    dbg.start

    class Foo
      def initialize(x)
        @x = x
        p @x
      end
    end

    # Beware: __LINE__ changed between those two lines.
    Breakpoint.new(Foo.instance_method(:initialize), __LINE__ - 6).enable
    Breakpoint.new(Foo.instance_method(:initialize), __LINE__ - 6).enable

    Foo.new 10
{:.ruby}

The output being simply:

    Instance variables: []
    Instance variables: []
    Instance variables: ["@x"]
    10
{:.term}

Defered breakpoints
-------------------

Breaking when you already have a method object is easy. However, when you do not
have a such object — because the method isn't defined yet — it is not as easy to
do. Still, it is not hard. :)

Since the method isn't defined, you need to check if it has been defined
whenever new methods could have been added. We can simply add a hook for that in
our initialize method, and create a class for defered breakpoint.

However, what happens when a method is defined and then gets overriden (which
happens when a class is monkey-patched or subclassed)? In that case, we would
definitely want the breakpoint to apply on the new method. So in this example
we'll just always keep a reference to the defered breapkoint — even though one
may want to implement something smarter than this.

    class DeferedBreakpoint
      def initialize(klass, method, class_method, line)
        @klass        = klass
        @method       = method
        @class_method = class_method
        @line         = line
      end

      # Try to create a Breakpoint object
      def resolve
        # Try to get the class that defines the method from its name
        klass = @klass.split('::').inject(Object) do |mod, const_name|
          if mod.is_a? Module and mod.const_defined?(const_name)
            mod.const_get(const_name)
          else
            break
          end
        end

        # Could not find the class, or its neither a class nor a module
        return unless klass and klass.is_a? Module

        # Try to get the method
        method = if @class_method
                   klass.method(@method) if klass.respond_to?(@method, true)
                 else
                   if klass.method_defined?(@method) ||
                       klass.private_method_defined?(@method) ||
                       klass.private_method_defined?(@method)
                     klass.instance_method(@method)
                   end
                 end

        # No such method
        return unless method

        # Everything is fine, return the breakpoint
        Breakpoint.new(method, @line)
      end
    end

    def initialize(&block)
      # Same as before
      @block   = block
      @thread  = nil

      # Keep a reference to each defered breapkoint
      @defered_breakpoints = []

      # Define a hook to create actual breakpoints from our defered
      # breapkoints.
      hook = proc { check_defered_breakpoints }

      Rubinius::CodeLoader.loaded_hook.add hook
      Rubinius.add_method_hook.add hook
    end

    def check_defered_breakpoints
      @defered_breakpoints.each do |current_bp|
        # Just create a breakpoint for each entry that maps to an actual
        # method call.
        if actual_bp = current_bp.resolve
          actual_bp.enable
        end
      end
    end

    # Helper method that creates a defered breakpoint, and resolves it right
    # away if possible.
    def add_breakpoint(klass, method, class_method, line)
      bp = DeferedBreakpoint.new(klass, method, class_method, line)

      @defered_breakpoints << bp

      if resolved_bp = bp.resolve
        resolved_bp.enable
      end
    end
{:.ruby}

And just in case you would not trust me when I say it works:

    dbg = Debugger.new do |bp, thread, locs|
      loc = locs.first
      puts "reached breakpoint at #{loc.file}:#{loc.line}"
    end

    dbg.start
    dbg.add_breakpoint "Foo", :initialize, false, 0

    class Foo
      def initialize(x)
        @x = x
      end
    end

    Foo.new "3"
{:.ruby}

    reached breakpoint at rbx_trace.rb:159
    reached breakpoint at rbx_trace.rb:164
{:.term}

Stop at next line
---------------

Often, the user will not simply want to break on a method. He will want to go to
the next line, and see what changed at that line. Thus, we will need to break on
the next lien. This is not as easy to do as it sounds: what's the next line this
example?

    loop do
      puts 3
      puts 4 # <= You are here
    end

    puts 5
{:.ruby}

It is indeed the line that says "puts 3", since we are in a loop. Such
structures must be taken in acount when implementing stepping. In fact, we'll
use the bytecode rubinius generated to figure out what's the next line.

Once we did that, we can just add a breakpoint which we'll remember to
remove. This involves changing our ``#listen`` method, which will just clear our
array of temporary breakpoints every time we reach one.

    def listen
      loop do
        bp, thread, chan, locs = @local_channel.receive

        @temporary_breakpoints.each(&:disable)
        @temporary_breakpoints.clear

        @block.call bp, thread, locs

        chan << true
      end
    end
{:.ruby}

The real thing is adding the breakpoint. We'll create a ``next(frames)`` method,
where frames is the backtrace as an array of ``Frame`` objects (that is,
``locs.map { |l| Frame.new(l) }``). It will just try to see if there's a line
after the current one. If there is, then it will put a breakpoint on the next
relevant instruction. If there is no such instruction, it will return back to
the previous element of the backtrace.

    def next!(frames)
      frame = frames.first
      exec  = frames[0].loc.method

      # I don't know what "fin" stands for in the actual Rubinius source code.
      # I will assume it is the French for "end", "end" not being allowed as a
      # variable name. :)
      #
      # It contains the location of the next line. It will thus be nil if this
      # is the last line.
      fin = exec.first_ip_on_line(frame.loc.line + 1, frame.loc.ip)

      if fin
        # More work to do. :(
        set_breakpoints_between(exec, frame.loc.ip, fin)
      else
        if frames[1] # If there's a previous element in the backtrace
          # Create a temporary breakpoint on that element.
          bp = Breakpoint.new(frames[1].loc.method, frames[1].loc.ip, true)
          bp.enable
          @temporary_breakpoints << bp
          bp
        end
      end
    end

    def set_breakpoints_between(exec, start, fin)
      # goto_between will return an array with the locations of the places we
      # should but a temporary breakpoint at. The important part of the work
      # isn't here yet. :p
      goto_between(exec, start, fin).each do |ip|
        bp = Breakpoint.new(exec, ip, true)
        bp.enable
        @temporary_breakpoints << bp
      end
    end

    def next_interesting(exec, ip)
      # Not important yet. We'll just ignore pop instructions.
      pop = Rubinius::InstructionSet.opcodes_map[:pop]

      if exec.iseq[ip] == pop
        ip + 1
      else
        ip
      end
    end

    def goto_between(exec, start, fin)
      # This is where we will do the job!
      # If we reach one of those goto instructions, we'll put a breakpoint
      # on their target; if not, we just continue

      goto = Rubinius::InstructionSet.opcodes_map[:goto]
      git  = Rubinius::InstructionSet.opcodes_map[:goto_if_true]
      gif  = Rubinius::InstructionSet.opcodes_map[:goto_if_false]

      iseq = exec.iseq

      i = start
      while i < fin # Iterate over instructions
        op = iseq[i]

        # Check if we reach a goto.
        case op
        when goto
          return [next_interesting(exec, iseq[i + 1])]
        when git, gif
          return [next_interesting(exec, iseq[i + 1]),
                  next_interesting(exec, iseq[i + 2])]
        end

        # Move to the next instruction. :)
        op = Rubinius::InstructionSet[op]
        i += op.arg_count + 1
      end

      # Nothing, just return the instruction we had initially found.
      [next_interesting(exec, fin)]
    end
{:.ruby}

Here's a test that will make us go to next if self.class.name is "Foo" (I
simply avoided checking for a constant that could possibly not exist :p):


    dbg = Debugger.new do |bp, thread, locs|
      loc = locs.first
      puts "reached breakpoint at #{loc.file}:#{loc.line}"

      if Debugger::Frame.new(loc).run("self.class.name") == "Foo"
        dbg.next! locs.map { |l| Debugger::Frame.new(l) }
      end
    end

    dbg.start
    dbg.add_breakpoint "Foo", :initialize, false, 0

    class Foo
      def initialize(x)
        @x = x
        @x
        3
      end
    end

    Foo.new "3"
    3
    4 # Random instructions to see if something happens.
    5
{:.ruby}

    reached breakpoint at rbx_trace.rb:240
    reached breakpoint at rbx_trace.rb:245
    reached breakpoint at rbx_trace.rb:246
    reached breakpoint at rbx_trace.rb:247
    reached breakpoint at rbx_trace.rb:251
{:.term}

Stepping into code
------------------

Stepping is pretty similar to the next command. The difference is that it steps
into method calls that can be seen. Regarding the implementation, there's quite
an easy way to step: instead of sending ``true`` to a channel, we'll send
``:step``, and Rubinius will deal with it for us.

    attr_accessor :stepping
    alias stepping? stepping

    def listen
      loop do
        bp, thread, chan, locs = @local_channel.receive

        @temporary_breakpoints.each(&:disable)
        @temporary_breakpoints.clear

        @block.call bp, thread, locs

        # New magic here: step if stepping is true
        if stepping?
          chan << :step
          @stepping = false
        else
          chan << true
        end
      end
    end

    # So, this is just the same as next!, except we set stepping to true.
    def step!(frames)
      next! frames
      self.stepping = true
    end
{:.ruby}

    dbg = Debugger.new do |bp, thread, locs|
      loc = locs.first
      puts "reached breakpoint at #{loc.file}:#{loc.line}"

      if loc.method.name == :start
        dbg.step! locs.map { |l| Debugger::Frame.new(l) }
      end
    end

    dbg.start # line 268
    dbg.add_breakpoint "Foo", :start, true, 0

    class Foo
      def self.fibo(n)
        case n
        when 0, 1 then 1
        else fibo(n - 1) + fibo(n - 2) # line 273
        end
      end

      def self.start
        fibo 10 # line 280
      end
    end

    Foo.start
{:.ruby}

    reached breakpoint at rbx_trace.rb:268
    reached breakpoint at rbx_trace.rb:280
    reached breakpoint at rbx_trace.rb:273
{:.term}

Had we not enabled stepping, we would not have reached a breakpoint at line
273. The program would have stopped directly, without letting you inspect code
in Foo.fibo.

Conlusion
---------

There's more to know to write a real debugger, and the debugger provided by
Rubinius uses more than the features I explained. This can still be enough to
understand how to create a such debugger, and how the one that Rubinius contains
basically works — and you can just read its source code if you want to know
more.
