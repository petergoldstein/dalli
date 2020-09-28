# frozen_string_literal: true

module Dalli
  module Protocol
    # Implements the NullObject pattern to store an application-defined value for 'Key not found' responses.
    class NilObject; end
    NOT_FOUND = NilObject.new
  end
end
