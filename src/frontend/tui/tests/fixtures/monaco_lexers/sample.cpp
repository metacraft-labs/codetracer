// A C++ sample.
#include <iostream>
#include <vector>
#include <string>

namespace geometry {

/** A templated point. */
template <typename T>
class Point {
public:
    Point(T x, T y) : x_(x), y_(y) {}
    virtual ~Point() = default;
    T dot(const Point& other) const noexcept { return x_ * other.x_ + y_ * other.y_; }
private:
    T x_, y_;
};

}  // namespace geometry

auto raw = R"(a raw "string")";

int main() {
    std::vector<geometry::Point<double>> points{{1.0, 2.0}, {3.5, -4.25}};
    constexpr int limit = 0b1010;
    for (const auto& p : points) {
        if (p.dot(points[0]) > limit) {
            std::cout << "big" << std::endl;
        }
    }
    int* ptr = nullptr;
    bool ok = ptr == nullptr && true;
    return ok ? 0 : 1;
}
