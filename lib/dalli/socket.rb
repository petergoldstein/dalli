if defined?($KGIO_NOT_ALLOWED) && $KGIO_NOT_ALLOWED
  require 'dalli/sockets/tcp'
else
  begin
    require 'dalli/sockets/kgio'
  rescue LoadError
    require 'dalli/sockets/tcp'
  end
end
