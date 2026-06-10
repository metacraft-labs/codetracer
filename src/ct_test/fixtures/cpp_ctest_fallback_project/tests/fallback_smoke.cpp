#include <iostream>
#include <string>

int main(int argc, char** argv) {
  if (argc == 2 && std::string(argv[1]) == "--named") {
    std::cout << "named fallback\n";
    return 0;
  }
  std::cout << "fallback smoke\n";
  return 0;
}
