require 'syskit/test/self'

describe Syskit::InvalidAutoConnection do
    include Syskit::Test::Self

    describe "#pretty_print" do
        it "should not raise" do
            source = flexmock(:each_output_port => [], :each_input_port => [])
            sink   = flexmock(:each_output_port => [], :each_input_port => [])
            PP.pp(Syskit::InvalidAutoConnection.new(source, sink), "")
        end
    end
end
