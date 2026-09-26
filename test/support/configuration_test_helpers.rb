module ConfigurationTestHelpers
  # Sets RailsPulse.configuration attributes for the duration of the block, using real
  # assignment (not a stub), and restores the previous values in ensure.
  def with_configuration(**overrides)
    originals = overrides.keys.index_with { |key| RailsPulse.configuration.public_send(key) }
    overrides.each { |key, value| RailsPulse.configuration.public_send("#{key}=", value) }

    yield
  ensure
    originals.each { |key, value| RailsPulse.configuration.public_send("#{key}=", value) }
  end

  # Swaps Rails.env for the duration of the block and restores it in ensure.
  def with_rails_env(name)
    original = Rails.env
    Rails.env = name.to_s

    yield
  ensure
    Rails.env = original
  end
end
