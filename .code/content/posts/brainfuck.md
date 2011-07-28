---
title: Brainfuck on Rubinius
now: Wed Jun 29 08:31:23 2011
---

Brainfuck is a very powerful and useful language — surely, millions of people
write their shell scripts in Brainfuck. The simplicity of its syntax makes it
even more powerful — only 8 instructions.
[this is if you don't know Brainfuck](http://en.wikipedia.org/wiki/Brainfuck).

So, the most common use-case of Brainfuck is implementing it. We could easily
write an interpreter for it, but we can make it even funnier. We can generate
bytecode to make it run even faster! And Rubinius provides what we need to
generate such bytecode. :)

The parser
----------

As I said, Brainfuck is very complex. We must definitely use a parser to get AST
nodes out of Brainfuck code. But I'll still do it by hand, regardless of
fear. Not only would I dare to do it with ``String#[]``, I will require one of
those rusted classes from stdlib — one of the underused ones. ``StringScanner``.

So, let's write one of those parsers. The first thing we need is a bunch of AST
nodes. We will only have a few instructions: printing the current character
(``Out``), asking the user for input (``Inp``), changing the current value using
+ and - (``ValVar``), changing the current cell using > and < (``PosVar``), and
loops (``Loop``). So we just need empty classes for now.

    module Brainfuck
      module AST
        class Out
        end

        class Inp
        end

        ValVar = Struct.new :size do
        end

        PosVar = Struct.new :size do
        end

        Loop = Struct.new :seq do
        end

        # top-level node
        Script = Struct.new :seq do
        end
      end
    end
{:.ruby}

Now, the parser! It will simply go through the Brainfuck code, and generate
nodes for each part of the code. We'll keep track of the amount of position and
value variations. When we reach an instruction that doesn't change the position,
we reset the position counter and generate the ``PosVar``; same with ``ValVar``.

    require 'strscan'

    module Brainfuck
      module Parser
        class Error < StandardError
          def initialize
            super "unmatched brackets" # only possible error :)
          end
        end

        module_function
        def parse(code)
          AST::Script.new scan(StringScanner.new(code), 0)
        end

        def scan(scanner, depth)
          ret     = []
          pos_var = val_var = 0

          until scanner.eos?
            case scanner.getch
            when '.'
              generate_variations(ret, pos_var, val_var)
              pos_var = val_var = 0
              ret << AST::Out.new
            when ','
              generate_variations(ret, pos_var, val_var)
              pos_var = val_var = 0
              ret << AST::Inp.new

            when '+'
              generate_pos_variation(ret, pos_var)
              pos_var  = 0
              val_var += 1
            when '-'
              generate_pos_variation(ret, pos_var)
              pos_var  = 0
              val_var -= 1

            when '>'
              generate_val_variation(ret, val_var)
              val_var  = 0
              pos_var += 1
            when '<'
              generate_val_variation(ret, val_var)
              val_var  = 0
              pos_var -= 1

            when '['
              generate_variations(ret, pos_var, val_var)
              val_var = pos_var = 0
              ret << AST::Loop.new(scan(scanner, depth + 1))
            when ']'
              generate_variations(ret, pos_var, val_var)
              val_var = pos_var = 0

              if depth.zero?
                raise Error
              else
                return ret
              end
            end
          end

          if depth.zero?
            ret
          else
            raise Error
          end
        end

        def generate_variations(output, pos_var, val_var)
          generate_pos_variation(output, pos_var)
          generate_val_variation(output, val_var)
        end

        def generate_pos_variation(output, var)
          unless var.zero?
            output << AST::PosVar.new(var)
          end
        end

        def generate_val_variation(output, var)
          unless var.zero?
            output << AST::ValVar.new(var)
          end
        end
      end
    end
{:.ruby}

Does it work? Let's try it!

    pry(main)> load "bf_rbx.rb"
    => true
    pry(main)> cd Brainfuck::Parser
    pry(Brainfuck::Parser):1> parse "test"
    => (Brainfuck::AST::Script < Struct) {
      :seq => []
    }
    pry(Brainfuck::Parser):1> parse "[,.]"
    => (Brainfuck::AST::Script < Struct) {
      :seq => [
        [0] (Brainfuck::AST::Loop < Struct) {
          :seq => [
            [0] #<Brainfuck::AST::Inp:0x3798>,
            [1] #<Brainfuck::AST::Out:0x379c>
          ]
        }
      ]
    }
    pry(Brainfuck::Parser):1> parse ">>>< . >>+--< . -+ ."
    => (Brainfuck::AST::Script < Struct) {
      :seq => [
        [0] (Brainfuck::AST::PosVar < Struct) {
          :size => 2,
        },
        [1] #<Brainfuck::AST::Out:0x3ea0>,
        [2] (Brainfuck::AST::PosVar < Struct) {
          :size => 2,
        },
        [3] (Brainfuck::AST::ValVar < Struct) {
          :size => -1,
        },
        [4] (Brainfuck::AST::PosVar < Struct) {
          :size => -1,
        },
        [5] #<Brainfuck::AST::Out:0x3eb4>,
        [6] #<Brainfuck::AST::Out:0x3eb8>
      ]
    }
    pry(Brainfuck::Parser):1> parse "test +[-]+"
    => (Brainfuck::AST::Script < Struct) {
      :seq => [
        [0] (Brainfuck::AST::ValVar < Struct) {
          :size => 1
        },
        [1] (Brainfuck::AST::Loop < Struct) {
          :seq => [
            [0] (Brainfuck::AST::ValVar < Struct) {
              :size => -1,
            }
          ]
        },
        [2] (Brainfuck::AST::ValVar < Struct) {
          :size => 1
        }
      ]
    }
    pry(Brainfuck::Parser):1> parse "]"
    Brainfuck::Parser::Error: unmatched brackets
      from ./bf_rbx.rb:179:in `scan'
    pry(Brainfuck::Parser):1> parse "[]]"
    Brainfuck::Parser::Error: unmatched brackets
      from ./bf_rbx.rb:179:in `scan'
    pry(Brainfuck::Parser):1> parse "["
    Brainfuck::Parser::Error: unmatched brackets
      from ./bf_rbx.rb:191:in `scan'
{:.term}

This looks like what I expect! :)

Bytecode generation
-------------------

This part is the core of the work: it tells Rubinius how to run our code. Each
AST node must know how to generate its own bytecode. To teach this to our
objects, we'll give them a ``bytecode`` method.

### AST::Script

This one is where the code starts, so it will setup our environment: set the
current line (let's forget about that and just set it to one), the cursor
position, and the buffer. Then we just generate the bytecode for all the nodes
in the script. It will also be responsibly of setting the return value of the
brainfuck code (we'll set that to the used buffer).

Since Rubinius expects us to use the index of local variables, let's keep them
as constants to make the code clearer.

    module Brainfuck
      module AST
        Buffer  = 0
        Pointer = 1

        BufferSize = 3000

        Script = Struct.new :seq do
          def bytecode(g) # g is short for generator
            # let's say everything is in one line
            # (I'm sure setting it to the real value is useful to write a
            #  brainfuck debugger...)
            g.set_line 1

            g.meta_push_0       # push 0
            g.set_local Pointer # assign it to pointer
            g.pop               # pop 0
                                # (we must pop values we won't use)

            g.push_literal Array.new(BufferSize, 0) # push array
            g.set_local Buffer                      # assign it to buffer
            g.pop                                   # pop array

            seq.each do |o| # run code
              o.bytecode g
            end

            # This seems to make Rubinius check the variables we need, etc.
            g.use_detected

            g.push_local Buffer # push buffer
            g.ret               # return it
          end
        end
      end
    end
{:.ruby}

### AST::Node

We'll need to change the value of the buffer quite often, so writing a mixin to
generate code used for this will help us to avoid repititions.

    module Brainfuck
      module AST
        module Node
          def push_current(g)
            # This is how you do a method call:

            # Buffer[Pointer]
            g.push_local Buffer   # 1. push the receiver
            g.push_local Pointer  # 2. push arguments
            g.send :[], 1         # 3. send method, and specify argument count
          end

          def set_current(g)
            # Buffer[Pointer] = value

            g.push_local   Buffer  # push array
            g.push_local   Pointer # push index

            yield g                # use a block to push value

            g.send :[]=, 2         # call this
            g.pop                  # pop result
          end
        end
      end
    end
{:.ruby}

### AST::Out

This one simply writes the current value to stdout. For instance if current
element is set to 97, it will print "a".

    module Brainfuck
      module AST
        class Out
          include Node

          def bytecode(g)
            g.push_literal $stdout  # push $stdout
            push_current g          # push g
            g.send :chr, 0          # replace it with g.chr
            g.send :print, 1        # print it
            g.pop                   # pop result
          end
        end
      end
    end
{:.ruby}

### AST::Inp

This is just the opposite: get a byte from stdin. We'll call to_i on the result
so we'll get 0 at EOF (in which case getbyte returns nil).


    module Brainfuck
      module AST
        class Inp
          include Node

          def bytecode(g)
            set_current g do
              g.push_literal $stdin # push $stdin
              g.send :getbyte, 0    # get a byte
              g.send :to_i, 0       # call to i
            end
          end
        end
      end
    end
{:.ruby}

### AST::ValVar

This could just be "add size to the current value", but it would not work. We
want our value to stay a valid byte (we could implement Brainfuck with unicode
codepoints or anything else if we wanted to, though), so we must stay between 0
and 256. We'll thus set the current value to ``(current + size) % 256``.

    module Brainfuck
      module AST
        ValVar = Struct.new :size do
          include Node

          def bytecode(g)
            set_current g do
              push_current g      # push current value
              g.push_literal size # push size
              g.send :+, 1        # add them

              g.push_literal 256  # push 256
              g.send :%, 1        # mod
            end
          end
        end
      end
    end
{:.ruby}

### AST::PosVar

This is pretty much the same as ``ValVar``, except we do it for the cursor,
which must stay a valid index (between 0 and ``BufferSize``, 3000 in this
case).

    module Brainfuck
      module AST
        PosVar = Struct.new :size do
          def bytecode(g)
            g.push_local Pointer      # push pointer
            g.push_literal size       # push size
            g.send :+, 1              # add them

            g.push_literal BufferSize # push buffer size
            g.send :%, 1              # mod

            g.set_local Pointer       # set pointer
            g.pop                     # don't forget pop
          end
        end
      end
    end
{:.ruby}

### AST::Loop

Loops are the funniest part: you must implement this yourself:

    while buffer[pointer] != 0
      run_instructions
    end
{:.ruby}

To do this, the generator won't provide something to implement while
yourself. Instead, you'll have to use labels and gotos yourself. :)

    module Brainfuck
      module AST
        Loop = Struct.new :seq do
          include Node

          def bytecode(g)
            start, check = g.new_label, g.new_label # create a few labels

            g.goto check # first goto the place where we check if we must loop

            start.set! # this is the beginning of the loop

            seq.each do |o| # run the body
              o.bytecode g
            end

            check.set! # this is where we check the current value

            push_current g # push current value
            g.meta_push_0  # push 0
            g.send :==, 1  # compare

            g.goto_if_false start # continue if it's not 0
          end
        end
      end
    end
{:.ruby}

Compiler
--------

Rubinius' compiler interface uses stages to go from our code to whatever is the
output. We'll only use two stages, and let Rubinius handle the end of the work:
firstly, going from Brainfuck to AST, then, from AST to bytecode.

First step is quite easy, since we already have our parser to do it:

    module Brainfuck
      module Stages
        class Generator < Rubinius::Compiler::Stage
          # later!
        end

        class Code < Rubinius::Compiler::Stage
          stage      :bf_code
          next_stage Generator

          def initialize(compiler, last)
            super
            # tell the compiler we want to get the code
            compiler.parser = self
          end

          attr_accessor :code

          def run
            @output = Brainfuck::Parser.parse(@code)
            run_next
          end
        end
      end
    end
{:.ruby}

…and second step is easy as well, since we have ``AST::Script#bytecode`` :)

    module Brainfuck
      module Stages
        class Generator < Rubinius::Compiler::Stage
          next_stage Rubinius::Compiler::Encoder

          def initialize(compiler, last)
            super
            compiler.generator = self
          end

          def run
            @output = Rubinius::Generator.new
            @input.bytecode @output
            @output.close

            run_next
          end
        end
      end
    end
{:.ruby}

To trigger those steps, we'll just create or compiler class, but a very simple
one: we'll just create an instance to go from Brainfuck to a compiled method.

    module Brainfuck
      class Compiler < Rubinius::Compiler
        def self.compile_code(code)
          compiler = new :bf_code, :compiled_method
          compiler.parser.code = code
          compiler.run
        end
      end
    end
{:.ruby}

And now comes the method all this has been written for: ``Brainfuck#run``. We
just compile the code, setup a few things for Rubinius to work, and call it, at
last.

    module Brainfuk
      module_function
      def run(code)
        meth = Compiler.compile_code(code)
        meth.scope = binding.static_scope.dup
        meth.name = :__eval__

        script = Rubinius::CompiledMethod::Script.new(meth, "(eval)", true)
        script.eval_binding = binding
        script.eval_source  = code

        meth.scope.script = script

        be = Rubinius::BlockEnvironment.new
        be.under_context(binding.variables, meth)
        be.from_eval!
        be.call
      end
    end
{:.ruby}

Now let's see if all those efforts were vain, or if this works!

    pry(main)> load "bf_rbx.rb"
    => true
    pry(main)> Brainfuck.run("++++++++++[>+++++++>++++++++++>+++>+<<<<-]>++.>+.
    pry(main)* +++++++..+++.>++.<<+++++++++++++++.>.+++.------.--------.>+.>.");
    Hello World!
{:.term}

Now you can have fun and run complex scripts like
[this one](http://pascal.cormier.free.fr/gbf/tests/out.bf) on the Rubinius
VM. :)
