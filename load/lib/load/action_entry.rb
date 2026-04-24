# ABOUTME: Describes one selectable action and its selection weight.
# ABOUTME: The selector uses these entries to choose actions deterministically.
module Load
  ActionEntry = Data.define(:action_class, :weight)
end
