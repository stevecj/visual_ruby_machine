require 'rubygems'
require 'rack'
require 'pathname'
require 'json'

# When it's time to implement sandboxing, see
# https://github.com/tario/shikashi/blob/master/README
# also consider JRuby, etc.

module Machine ; module Runner ; end ;end
# Defined from top-level context, so will have top-level Module.nesting.
runner = Machine::Runner
def runner.source_binding
  binding
end

module Machine
  module Content
    Root = Pathname.new(__FILE__).parent

    def self.home
      Root.join('content', 'home.html').read
    end

    def self.jquery
      @jquery ||= Root.join('assets', 'scripts', 'jquery.min.js').read
    end
  end

  module Runner
    class << self
      attr_accessor :journal

      # TODO: Add total-event limiting, and journal size limiting.
      def run(sourcecode)
        # Prepend nil line for initial state capture.
        sourcecode = "nil\n#{sourcecode}"

        # This worked, but have not found out why for certain. Trying rescue the
        # exception outside of the eval did not work, and exceptions were rescued
        # by Rack instead. Something to do with using a binding?
        sourcecode = <<-CODE
          begin
            # Offset starting line by -1 (0 = 1 - 1) to match what the user
            # submitted, before we prepended a `nil` line.
            [ '>', eval(#{sourcecode.inspect}, binding, '~sourcecode~', 0).inspect ]
          rescue Exception
            # Use this form of rescue & global $! var, to prevent hoisting
            # an unwanted local variable.
            [ '!', $!.inspect, $!.backtrace ]
          ensure
            # In case a symbol was thrown, or some such.
            [ '?', $!.inspect ]
          end
        CODE

        self.journal = []
        journal << eval( sourcecode, source_binding, __FILE__, __LINE__ )
        journal     
      end
    end

    set_trace_func proc{|event, file, line, id, bynding, classname|
      if file == '~sourcecode~'
        locals = eval( "local_variables.sort.map{|n| [n.to_s, eval(n.to_s).inspect]}", bynding )
        Machine::Runner.journal << [ 
          ':', {'event' => event, 'line' => line, 'id' => id, 'classname' => classname, 'locals' => locals}
        ]
      end
    }
  end
end

Rack::Handler::Thin.run(
  proc {|env|
    case env['REQUEST_METHOD']
    when 'GET'
      case env['REQUEST_PATH']
      when '/'
        puts 'Rendering home'
        [ 200, {"Content-Type" => "text/html"          }, Machine::Content.home   ]
      when '/jquery.min.js'
        puts 'Rendering jquery'
        [ 200, {"Content-Type" => "application/jquery" }, Machine::Content.jquery ]
      else
        puts 'rendering 404 for GET'
        [ 404, {"Content-Type" => "text/html" }, 'Not Found' ]
      end
    when 'POST'
      puts 'rendering js as POST response'
      postdata = env['rack.input'].read.to_s
      sourcecode = JSON.parse(postdata)['sourcecode']
      journal = Machine::Runner.run(sourcecode)
      js = <<-JS
        (function(){
          $('#status').html('');
          var journal = #{journal.to_json()};
          $.each(journal, function(i,v){
            var line = $('<div>');
            line.text( JSON.stringify(v) );
            $('#status').append( line );
          });
        })();
      JS
      [ 200, {"Content-Type" => "application/javascript"}, js ]
    else
      puts 'rendering 404 as response to unrecognized HTTP method'
      [ 404, {"Content-Type" => "text/html" }, 'Not Found' ]
    end
  },
  :Port => 9292
)
