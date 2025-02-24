$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift(File.dirname(__FILE__))
require 'rspec'
require 'ruby'

describe Ruby do
  it 'can run a correct ast' do
    extend Ruby::DSL
    ast = n(:module, [n(:binary_add, [n(:int, [0]), n(:int, [5])])])
    expect(run(ast)).to eq rint(5)
  end

  it 'fails on an incorrect ast' do
    extend Ruby::DSL
    ast = n(:module, [n(:binary_add, [n(:var, [:zero]), n(:int, [5])])])
    expect { run(ast) }.to raise_error(/no zero/)
  end
end
