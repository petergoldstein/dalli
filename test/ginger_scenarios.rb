require 'ginger'

Ginger.configure do |config|  
  rails_2_3_8 = Ginger::Scenario.new
  rails_2_3_8[/^rails$/] = "2.3.8"
  
  rails_3_0_0 = Ginger::Scenario.new
  rails_3_0_0[/^rails$/] = "3.0.0"
  
  config.scenarios << rails_2_3_8 << rails_3_0_0
end