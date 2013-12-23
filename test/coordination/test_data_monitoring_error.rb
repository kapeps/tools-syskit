require 'syskit/test/self'
require 'stringio'

describe Syskit::Coordination::DataMonitor do
    include Syskit::Test::Self
    describe "#pretty_print" do
        it "does not raise" do
            monitor = Syskit::Coordination::DataMonitoringError.
                new(Roby::Task.new, flexmock, flexmock, [flexmock])
            pp = PP.new(StringIO.new)
            monitor.pretty_print(pp)
        end
    end
end

