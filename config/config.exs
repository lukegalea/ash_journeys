import Config

# The package needs no configuration; the test fixtures are Ash resources.
if config_env() == :test do
  config :ash, default_string_length_count: :codepoints
end
