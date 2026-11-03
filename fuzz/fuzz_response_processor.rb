# frozen_string_literal: true

# Entry point for the fuzz_response_processor target. Ruzzy instruments pure Ruby code
# only when it's loaded after tracing starts, so the harness is loaded here.
require 'ruzzy'

Ruzzy.trace(File.join(__dir__, 'fuzz_response_processor_harness.rb'))
