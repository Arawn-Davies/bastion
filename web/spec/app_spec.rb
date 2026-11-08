require 'spec_helper'
require 'json'

# Stubbed IPMI results so specs never touch a real BMC.
STUB = {
  'ilo' => { power: 'on', ok: true, watts: '40 Watts',
             temps: [['Ambient Temp', '24 degrees C', 'ok']],
             fans:  [['FAN 1', '3000 RPM', 'ok']], volts: [], sel: [] },
  'idrac' => { power: 'on', ok: true, watts: '168 Watts',
               temps: [['Ambient Temp', '24 degrees C', 'ok']],
               fans:  [['FAN MOD 1A', '3360 RPM', 'ok']], volts: [], sel: [] },
}.freeze

def json_post(node, action)
  post '/power', { node: node, action: action }.to_json,
       'CONTENT_TYPE' => 'application/json'
end

RSpec.describe BMC do
  # Auth is enforced (PLATFORM_* set in spec_helper), so the app is gated.
  describe 'authentication' do
    it 'redirects an unauthenticated request to /login' do
      get '/dashboard'
      expect(last_response.status).to eq(302)
      expect(last_response.headers['Location']).to include('/login')
    end

    it 'serves the login page' do
      get '/login'
      expect(last_response).to be_ok
      expect(last_response.body).to include('Sign in')
    end

    it 'grants access with correct local credentials' do
      login_local!
      expect(last_response.status).to eq(302)
      get '/'
      expect(last_response).to be_ok
      expect(last_response.body).to include('iLO2 Console')
    end

    it 'rejects wrong local credentials' do
      post '/login', user: 'tester', pass: 'nope'
      expect(last_response.status).to eq(401)
      get '/dashboard'
      expect(last_response.status).to eq(302)
    end

    it 'admits an allowlisted GitHub user' do
      mock_github('Arawn-Davies')
      get '/auth/github/callback'
      expect(last_response.status).to eq(302)
      get '/'
      expect(last_response).to be_ok
    end

    it 'denies a non-allowlisted GitHub user' do
      mock_github('someone-else')
      get '/auth/github/callback'
      expect(last_response.status).to eq(403)
    end

    describe 'OpenID Connect' do
      it 'offers single sign-on on the login page, CSRF-protected' do
        get '/login'
        expect(last_response.body).to include('action="/auth/oidc"', 'Sign in with single sign-on', 'authenticity_token')
      end

      it 'admits a member of an allowed group' do
        mock_oidc(nickname: 'alice', email: 'alice@example.test', groups: ['BMC Admins'])
        get '/auth/oidc/callback'
        expect(last_response.status).to eq(302)
        get '/'
        expect(last_response).to be_ok
      end

      it 'admits an allowed user by email, case-insensitively' do
        mock_oidc(nickname: 'ops', email: 'OPS@example.test', groups: [])
        get '/auth/oidc/callback'
        expect(last_response.status).to eq(302)
        get '/dashboard'
        expect(last_response).to be_ok
      end

      it 'denies a valid IdP user who is in neither allow-list' do
        mock_oidc(nickname: 'mallory', email: 'mallory@example.test', groups: ['Everyone'])
        get '/auth/oidc/callback'
        expect(last_response.status).to eq(403)
        expect(last_response.body).to include('mallory is not authorised')
        get '/dashboard'
        expect(last_response.headers['Location']).to include('/login')
      end

      it 'is fail-closed when no allow-list is configured' do
        stub_const('OIDC_ALLOWED_USERS', [])
        stub_const('OIDC_ALLOWED_GROUPS', [])
        mock_oidc(nickname: 'alice', email: 'alice@example.test', groups: ['BMC Admins'])
        get '/auth/oidc/callback'
        expect(last_response.status).to eq(403)
      end

      it 'does not trust a group name that only partially matches' do
        mock_oidc(nickname: 'eve', email: 'eve@example.test', groups: ['BMC Admins (read-only)', 'bmc admins'])
        get '/auth/oidc/callback'
        expect(last_response.status).to eq(403)
      end

      it 'returns 404 for the callback when OIDC is not configured' do
        stub_const('OIDC_ISSUER', '')
        get '/auth/oidc/callback'
        expect(last_response.status).to eq(404)
      end

      it 'shows the IdP error on failure without echoing markup' do
        get '/auth/failure', strategy: 'oidc', message: '<script>x</script>'
        expect(last_response.status).to eq(401)
        expect(last_response.body).to include('Single sign-on failed')
        expect(last_response.body).not_to include('<script>x</script>')
      end
    end

    it 'logs out' do
      login_local!
      get '/logout'
      expect(last_response.status).to eq(302)
      get '/dashboard'
      expect(last_response.headers['Location']).to include('/login')
    end
  end

  context 'when authenticated' do
    before { login_local! }

    describe 'GET /' do
      it 'renders the landing page with all three entry points' do
        get '/'
        expect(last_response).to be_ok
        expect(last_response.body).to include('iLO2 Console', 'iDRAC6 Console', 'IPMI Dashboard')
      end
    end

    describe 'GET /dashboard' do
      before { allow_any_instance_of(BMC).to receive(:gather_all).and_return(STUB) }

      it 'renders both nodes with live readings and controls' do
        get '/dashboard'
        expect(last_response).to be_ok
        expect(last_response.body).to include('HP-NODE', 'DELL-NODE',
                                              '40 Watts', '168 Watts',
                                              'Power On', 'Force Off')
      end
    end

    describe 'POST /power' do
      it 'runs a valid power action' do
        allow_any_instance_of(BMC).to receive(:ipmi).and_return('Chassis Power Control: Cycle')
        json_post('idrac', 'cycle')
        expect(last_response).to be_ok
        expect(last_response.body).to include('DELL-NODE', 'cycle')
      end

      it 'rejects an unknown node' do
        json_post('nope', 'on')
        expect(last_response.status).to eq(400)
      end

      it 'rejects an unknown action' do
        json_post('idrac', 'explode')
        expect(last_response.status).to eq(400)
      end
    end

    describe 'GET /console/:key' do
      before { allow(Net::HTTP).to receive(:post) } # do not fire a real launch

      it 'embeds noVNC for a known node' do
        get '/console/ilo'
        expect(last_response).to be_ok
        expect(last_response.body).to include('/novnc/vnc.html', 'HP-NODE')
      end

      it 'fires the launch on the engine for a known node' do
        get '/console/idrac'
        expect(Net::HTTP).to have_received(:post)
      end

      it '404s an unknown node' do
        get '/console/bogus'
        expect(last_response.status).to eq(404)
      end
    end

    describe 'POST /console/:key/:action (reload/exit)' do
      before { allow(Net::HTTP).to receive(:post) }

      it 'reloads a console' do
        post '/console/ilo/reload'
        expect(last_response).to be_ok
        expect(Net::HTTP).to have_received(:post)
      end

      it 'exits a console' do
        post '/console/idrac/exit'
        expect(last_response).to be_ok
      end

      it 'rejects an unknown action' do
        post '/console/ilo/bogus'
        expect(last_response.status).to eq(400)
      end

      it '404s an unknown node' do
        post '/console/nope/reload'
        expect(last_response.status).to eq(404)
      end
    end

    describe 'GET /serial/:id' do
      it 'renders the SOL terminal for a node with an ip' do
        post '/servers', label: 'SOLBOX', ip: '192.0.2.7', user: 'u', pass: 'p', vendor: 'other'
        id = Store.all.find { |s| s[:label] == 'SOLBOX' }[:id]
        get "/serial/#{id}"
        expect(last_response).to be_ok
        expect(last_response.body).to include("/solws/#{id}", 'xterm')
      end

      it '400s a node without a BMC ip' do
        post '/servers', label: 'NOIP', ip: '', vendor: 'other'
        id = Store.all.find { |s| s[:label] == 'NOIP' }[:id]
        get "/serial/#{id}"
        expect(last_response.status).to eq(400)
      end

      it '404s an unknown node' do
        get '/serial/bogus'
        expect(last_response.status).to eq(404)
      end
    end

    describe 'server CRUD' do
      it 'creates a server' do
        post '/servers', label: 'NEWBOX', ip: '192.0.2.5', user: 'admin', pass: 'pw', vendor: 'other', fan_max: '9000'
        expect(last_response.status).to eq(302)
        added = Store.all.find { |s| s[:label] == 'NEWBOX' }
        expect(added).not_to be_nil
        expect(added[:ip]).to eq('192.0.2.5')
        expect(added[:id]).not_to be_empty
      end

      it 'updates a server and keeps the password when left blank' do
        before_pass = Store.find('ilo')[:pass]
        post '/servers', id: 'ilo', label: 'RENAMED', ip: '192.0.2.9', user: 'u', pass: '', vendor: 'hp', fan_max: '18000'
        s = Store.find('ilo')
        expect(s[:label]).to eq('RENAMED')
        expect(s[:ip]).to eq('192.0.2.9')
        expect(s[:pass]).to eq(before_pass)
      end

      it 'deletes a server' do
        post '/servers', label: 'TODELETE', ip: '192.0.2.6', vendor: 'other'
        id = Store.all.find { |s| s[:label] == 'TODELETE' }[:id]
        post "/servers/#{id}/delete"
        expect(Store.find(id)).to be_nil
      end
    end
  end
end
