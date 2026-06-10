require "spec"
require "../src/calculator"

describe "calculator" do
  it "adds numbers" do
    CtM11Crystal.add(2, 3).should eq(5)
  end

  context "doubling" do
    it "doubles values" do
      CtM11Crystal.double(4).should eq(8)
    end
  end
end
