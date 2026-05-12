# tend

Ruby SDK for [Tend](https://tend.justinpaulson.com) error capture. First-party Rack middleware + Rails error reporter subscriber. Sends backend exceptions to Tend's webhook ingest endpoint.

## Install

```ruby
# Gemfile
gem "tend", git: "https://github.com/justinpaulson/tend-ruby"
```

## Configure (Rails)

```ruby
# config/initializers/tend.rb
Tend.configure do |c|
  c.ingest_token = ENV["TEND_INGEST_TOKEN"]
end
```

That's it. The Railtie auto-installs the middleware and subscribes to `Rails.error` on boot. No further setup needed for Rails apps.

If `ingest_token` is missing, the SDK logs a single warning at boot and stays inert — your app keeps booting.

## Where do I find the ingest token?

Each Tend project has its own ingest token. Open the project in the Tend UI → Settings → "Ingest token". One token per project. Multi-app deployments need one initializer per app pointing at that app's project token.

## Manual capture

```ruby
begin
  do_thing
rescue => e
  Tend.capture_exception(e, extra: { user_id: current_user.id })
end

Tend.capture_message("payment partial failure", level: "warning", extra: { order_id: 42 })
```

## User attribution

Attach a `user` object to every captured event so Tend can attribute errors to a specific user. Three APIs:

- `Tend.set_user(id:, email:, **extras)` — sets the process-wide user (stored on `configuration.user`). Useful for single-tenant processes / scripts.
- `Tend.with_user(id:, email:, **extras) { ... }` — sets a thread-local user for the duration of the block, then restores the prior value. Use this in request-scoped code (Rails around_action, Sidekiq middleware, etc.) so concurrent requests don't bleed.
- `Tend.clear_user` — clears the global user. Does not touch the thread-local.

Resolution order on each event: `Thread.current[:tend_user]` → `configuration.user` → omitted.

### Rails: per-request user via `around_action`

```ruby
class ApplicationController < ActionController::Base
  around_action :tend_user_context

  def tend_user_context
    if Current.user
      Tend.with_user(id: Current.user.id, email: Current.user.email) { yield }
    else
      yield
    end
  end
end
```

This wraps each action so any error reported via `Rails.error.report` (the Railtie's error subscriber path) sees the current user. Note: the Rack middleware path catches *re-raised* exceptions after the around_action has unwound — so middleware-time captures see the global `configuration.user`, not the thread-local. For middleware-time attribution, either set the user globally with `Tend.set_user` or wrap `Tend::Middleware` in a Rack middleware that sets `Thread.current[:tend_user]` itself.

Extras passed to `set_user`/`with_user` are included in the user object as-is — keep them JSON-safe primitives.

## Configuration reference

| Option | Default | Notes |
|---|---|---|
| `ingest_token` | `nil` | Required. From Tend project settings. |
| `ingest_url` | `https://tend.justinpaulson.com/api/error_events` | Override for self-hosted Tend. |
| `release` | `nil` | Git SHA / version tag. |
| `environment` | `Rails.env` (Railtie) | Override per app. |
| `tags` | `{ hostname: Socket.gethostname }` | Hash merged into every event. |
| `before_send` | identity | Lambda; return `nil` to drop event. |
| `ignored_exceptions` | Common Rails noise | Class names matched against ancestor chain. |
| `logger` | `Rails.logger` or `Logger.new($stdout)` | SDK warnings go here. |
| `user` | `nil` | Process-wide user hash sent with every event. Prefer `Tend.set_user` / `Tend.with_user`. |

## Non-Rails Rack apps

```ruby
# config.ru
require "tend"
Tend.configure { |c| c.ingest_token = ENV["TEND_INGEST_TOKEN"] }
use Tend::Middleware
run YourApp
```

## Behavior

- **Async:** events go through a single worker thread + bounded queue (size 100). Drops on overflow with a warn log.
- **Timeouts:** 2s open + 2s read on Net::HTTP.
- **Never raises:** all errors (network, 4xx, 5xx) are swallowed and logged at warn level.
- **No retries:** on 429 or 5xx the event is dropped to avoid stampeding.
- **Reraises in middleware:** the original exception always propagates; capturing is fire-and-forget.

## Development

```bash
bundle install
bundle exec rake test
gem build tend.gemspec
```

## License

MIT
