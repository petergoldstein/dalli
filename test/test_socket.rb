require 'helper'

describe 'Socket' do

  describe 'loads kgio' do

    it "loads kgio if available" do
      ancestors = Dalli::Server::KSocket.ancestors
      assert_includes ancestors, Kgio::Socket
    end

  end

end