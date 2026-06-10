require "spec_helper"

RSpec.describe "top level strings" do
  it "supports another file" do
    expect("ruby".upcase).to eq("RUBY")
  end
end
