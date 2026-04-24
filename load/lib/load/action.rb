# ABOUTME: Declares the base class for load runner actions.
# ABOUTME: Concrete actions provide their own name and execution behavior.
module Load
  class Action
    def initialize(rng:, ctx:, client:)
      @rng = rng
      @ctx = ctx
      @client = client
    end

    attr_reader :rng, :ctx, :client

    def name
      raise NotImplementedError
    end

    def call
      raise NotImplementedError
    end
  end
end
