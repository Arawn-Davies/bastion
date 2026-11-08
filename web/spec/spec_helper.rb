ENV['RACK_ENV'] = 'test'
# Test auth config (must be set before app.rb reads them).
ENV['SESSION_SECRET']       ||= 'x' * 64
ENV['PLATFORM_USER']        ||= 'tester'
ENV['PLATFORM_PASS']        ||= 'testpass'
ENV['GITHUB_ALLOWED_USERS'] ||= 'Arawn-Davies'
ENV['GITHUB_CLIENT_ID']     ||= 'testid'
ENV['GITHUB_CLIENT_SECRET'] ||= 'testsecret'
ENV['OIDC_ISSUER']          ||= 'https://idp.example.test/'
ENV['OIDC_CLIENT_ID']       ||= 'bastion'
ENV['OIDC_CLIENT_SECRET']   ||= 'oidcsecret'
ENV['OIDC_REDIRECT_URI']    ||= 'https://bastion.example.test/auth/oidc/callback'
ENV['OIDC_ALLOWED_USERS']   ||= 'ops@example.test'
ENV['OIDC_ALLOWED_GROUPS']  ||= 'BMC Admins'

require 'tmpdir'
ENV['SERVERS_PATH'] ||= File.join(Dir.tmpdir, 'bastion_servers_test.json')

require 'rack/test'
require 'omniauth'
require 'omniauth-github'
require 'omniauth_openid_connect'
require_relative '../app'

OmniAuth.config.test_mode = true
OmniAuth.config.logger = Logger.new(File::NULL)

module AppHelper
  # Full Rack stack (session + OmniAuth) wrapping the Sinatra app, mirroring
  # config.ru so auth behaves in tests as it does in production.
  def app
    @app ||= Rack::Builder.app do
      use Rack::Session::Cookie, secret: ENV['SESSION_SECRET'], same_site: :lax
      use OmniAuth::Builder do
        provider :github, ENV['GITHUB_CLIENT_ID'], ENV['GITHUB_CLIENT_SECRET']
        provider :openid_connect, name: :oidc, issuer: ENV['OIDC_ISSUER'], discovery: false,
                 response_type: :code, pkce: true,
                 client_options: { identifier: ENV['OIDC_CLIENT_ID'], secret: ENV['OIDC_CLIENT_SECRET'],
                                   redirect_uri: ENV['OIDC_REDIRECT_URI'] }
      end
      run BMC
    end
  end

  def login_local!
    post '/login', user: ENV['PLATFORM_USER'], pass: ENV['PLATFORM_PASS']
  end

  def mock_github(nickname)
    OmniAuth.config.mock_auth[:github] = OmniAuth::AuthHash.new(info: { nickname: nickname })
  end

  def mock_oidc(nickname: nil, email: nil, groups: [])
    OmniAuth.config.mock_auth[:oidc] = OmniAuth::AuthHash.new(
      provider: 'oidc', uid: 'sub-1', info: { nickname: nickname, email: email },
      extra: { raw_info: { 'preferred_username' => nickname, 'groups' => groups } }
    )
  end
end

RSpec.configure do |c|
  c.include Rack::Test::Methods
  c.include AppHelper
  c.expect_with(:rspec) { |e| e.syntax = :expect }
  c.after do
    OmniAuth.config.mock_auth[:github] = nil
    OmniAuth.config.mock_auth[:oidc] = nil
  end
  # fresh server store each example (re-seeds the defaults on next read)
  c.before { File.delete(ENV['SERVERS_PATH']) if File.exist?(ENV['SERVERS_PATH']) }
end
