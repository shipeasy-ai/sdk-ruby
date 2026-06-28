# frozen_string_literal: true

class ApplicationController < ActionController::Base
  # No CSRF token needed — this example is a single read-only GET page.
  protect_from_forgery with: :null_session
end
