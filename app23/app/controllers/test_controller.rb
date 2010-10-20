class TestController < ApplicationController
  
  def index
    @session_time = session[:foo] ||= Time.now
    @cache_time = Rails.cache.fetch('current_time', :expires_in => 1.minute) do
      Time.now
    end
  end
end
