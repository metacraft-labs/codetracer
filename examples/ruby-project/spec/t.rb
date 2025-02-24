$LOAD_PATH.unshift(File.join(File.dirname(__FILE__), '..', 'lib'))
$LOAD_PATH.unshift(File.dirname(__FILE__))
require 'ruby'

trace = []

t = TracePoint.new(:call) do |tp|
  trace << [tp.lineno, tp.path, tp.method_id, tp.callee_id]
end

t2 = TracePoint.new(:line) do |tp|
  trace << [tp.lineno, tp.path, tp.method_id, 2]
end

t.enable
t2.enable

def x
  extend Ruby::DSL
  ast = n(:module, [n(:binary_add, [n(:int, [0]), n(:int, [5])])])
  run(ast)
end

eval("x()")

t.disable
t2.disable

puts trace.map { |a, b, m, c| "#{a}:#{b} method #{m} #{c}"}




# {
#   "CN": "kube01.node.cloudgear.ch",
#   "key": {
#     "algo": "rsa",
#     "size": 2048
#   },
#   "names": [{
#     "C": "CH",
#     "L" : "Zurich",
#     "O" : "CloudGear GmbH",
#     "OU" : "Kubebox",
#     "ST" : "ZH"
#   }],
#   "hosts" : ["localhost", "127.0.0.1", "kube01.node.cloudgear.ch", "node.cloudgear.ch", "cloudgear.ch", "163.172.158.199"]
# }


# cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=config.json -profile=client csr.json | cfssljson -bare kubebox    

# "client" : {
#           "usages" : [
#             "signing",
#             "key encipherment",
#             "client auth"
#           ],
#           "expiry" : "8760h"
#         },

# Key usage violation in certificate has been detected.


# cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=config.json -profile=server csr.json | cfssljson -bare kubebox    
# "server" : {
#           "usages" : [
#             "signing",
#             "key encipherment",
#             "server auth"
#           ],
#           "expiry" : "8760h"
#         }

# Key usage violation in certificate has been detected.

# cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=config.json -profile=kubebox csr.json | cfssljson -bare kubebox    
# "kubebox" : {
#           "usages" : [
#             "signing",
#             "key encipherment",
#             "server auth"
#           ],
#           "expiry" : "8760h"
#         }


# cfssl gencert -ca=ca.pem -ca-key=ca-key.pem -config=config.json -profile=client-server csr.json | cfssljson -bare kubebox    
# "client-server" : {
#           "usages" : [
#             "signing",
#             "key encipherment",
#             "server auth",
#             "client auth"
#           ],
#           "expiry" : "8760h"
#         }



# https://www.cis.upenn.edu/~bcpierce/sf/current/toc.html
# finish trace
# finish kubebox
# langu: vm gc, type system
# music: ml, process

# write family
# write 3 friends
