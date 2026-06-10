require "spec_helper"

class RubySliceCalculator
  def add(left, right)
    left + right
  end
end

RSpec.describe RubySliceCalculator do
  describe "addition" do
    context "with positive operands" do
      it "adds numbers" do
        expect(described_class.new.add(2, 3)).to eq(5)
      end

      it "handles zero" do
        expect(described_class.new.add(0, 3)).to eq(3)
      end
    end

    context "with negative operands" do
      specify "adds negatives" do
        expect(described_class.new.add(-2, -3)).to eq(-5)
      end
    end
  end

  shared_examples "commutative addition" do
    it "keeps the same result when operands flip" do
      calculator = described_class.new
      expect(calculator.add(4, 9)).to eq(calculator.add(9, 4))
    end
  end

  it_behaves_like "commutative addition"
end

fake = "it 'does not come from a string' do"
# it "does not come from a comment" do
