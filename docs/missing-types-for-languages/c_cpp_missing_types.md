A list of missing types in the C and C++ backends:

Sources: https://en.cppreference.com/
> [!CAUTION]
> Make sure to look for any C++ alternatives when implementing C types. Most C types have a C++ alternative that
> you should also add support for.

## C++

- [ ] std::pair - probably as a tuple?
- [ ] std::tuple
- [ ] std::optional
- [ ] std::expected
- [ ] std::variant - represent as union
- [ ] std::any
- [ ] std::bitset
- [ ] std::unique_ptr
- [ ] std::shared_ptr
- [ ] std::weak_ptr
- [ ] std::function
- [ ] std::basic_string<char>
- [ ] std::basic_string<wchar_t>
- [ ] std::basic_string<char8_t>
- [ ] std::basic_string<char16_t>
- [ ] std::basic_string<char32_t>
- [ ] std::string
- [ ] std::wstring
- [ ] std::u8string
- [ ] std::u16string
- [ ] std::u32string
- [ ] std::basic_string_view<char>
- [ ] std::basic_string_view<wchar_t>
- [ ] std::basic_string_view<char8_t>
- [ ] std::basic_string_view<char16_t>
- [ ] std::basic_string_view<char32_t>
- [ ] std::string_view
- [ ] std::wstring_view
- [ ] std::u8string_view
- [ ] std::u16string_view
- [ ] std::u32string_view
- [ ] std::pmr::basic_string<char> - \* 1
- [ ] std::pmr::basic_string<wchar_t> - \* 1
- [ ] std::pmr::basic_string<char8_t> - \* 1
- [ ] std::pmr::basic_string<char16_t> - \* 1
- [ ] std::pmr::basic_string<char32_t> - \* 1
- [ ] std::pmr::string - \* 1
- [ ] std::pmr::wstring - \* 1
- [ ] std::pmr::u8string - \* 1
- [ ] std::pmr::u16string - \* 1
- [ ] std::pmr::u32string - \* 1
- [ ] std::pmr::basic_string_view<char> - \* 1
- [ ] std::pmr::basic_string_view<wchar_t> - \* 1
- [ ] std::pmr::basic_string_view<char8_t> - \* 1
- [ ] std::pmr::basic_string_view<char16_t> - \* 1
- [ ] std::pmr::basic_string_view<char32_t> - \* 1
- [ ] std::pmr::string_view - \* 1
- [ ] std::pmr::wstring_view - \* 1
- [ ] std::pmr::u8string_view - \* 1
- [ ] std::pmr::u16string_view - \* 1
- [ ] std::pmr::u32string_view - \* 1
- [ ] std::filesystem::path
- [ ] std::regex - ?
- [ ] std::wregex - ?
- [ ] std::basic_regex<char> - ?
- [ ] std::basic_regex<wchar_t> - ?
- [ ] std::initializer_list
- [ ] std::array
- [ ] std::vector
- [ ] std::inplace_vector
- [ ] std::deque
- [ ] std::queue
- [ ] std::stack
- [ ] std::list
- [ ] std::forward_list
- [ ] std::inplace_vector
- [ ] std::set
- [ ] std::unordered_set
- [ ] std::map
- [ ] std::unordered_map
- [ ] std::multiset
- [ ] std::unordered_multiset
- [ ] std::multimap
- [ ] std::unordered_multimap
- [ ] std::flat_set
- [ ] std::flat_map
- [ ] std::flat_multiset
- [ ] std::flat_multimap
- [ ] std::span
- [ ] std::mdspan
- [ ] std::atomic_bool
- [ ] std::atomic_char
- [ ] std::atomic_schar
- [ ] std::atomic_uchar
- [ ] std::atomic_short
- [ ] std::atomic_int
- [ ] std::atomic_uint
- [ ] std::atomic_long
- [ ] std::atomic_ulong
- [ ] std::atomic_llong
- [ ] std::atomic_ullong
- [ ] std::atomic_char8_t
- [ ] std::atomic_char16_t
- [ ] std::atomic_char32_t
- [ ] std::atomic_int8_t
- [ ] std::atomic_uint8_t
- [ ] std::atomic_int16_t
- [ ] std::atomic_uint16_t
- [ ] std::atomic_int32_t
- [ ] std::atomic_uint32_t
- [ ] std::atomic_int64_t
- [ ] std::atomic_uint64_t
- [ ] std::atomic_int_least8_t
- [ ] std::atomic_uint_least8_t
- [ ] std::atomic_int_least16_t
- [ ] std::atomic_uint_least16_t
- [ ] std::atomic_int_least32_t
- [ ] std::atomic_uint_least32_t
- [ ] std::atomic_int_least64_t
- [ ] std::atomic_uint_least64_t
- [ ] std::atomic_int_fast8_t
- [ ] std::atomic_uint_fast8_t
- [ ] std::atomic_int_fast16_t
- [ ] std::atomic_uint_fast16_t
- [ ] std::atomic_int_fast32_t
- [ ] std::atomic_uint_fast32_t
- [ ] std::atomic_int_fast64_t
- [ ] std::atomic_uint_fast64_t
- [ ] std::atomic_intptr_t
- [ ] std::atomic_uintptr_t
- [ ] std::atomic_size_t
- [ ] std::atomic_ptrdiff_t
- [ ] std::atomic_intmax_t
- [ ] std::atomic_uintmax_t
- [ ] std::atomic<bool>
- [ ] std::atomic<char>
- [ ] std::atomic<signed char>
- [ ] std::atomic<unsigned char>
- [ ] std::atomic<short>
- [ ] std::atomic<int>
- [ ] std::atomic<unsigned int>
- [ ] std::atomic<long>
- [ ] std::atomic<unsigned long>
- [ ] std::atomic<long long>
- [ ] std::atomic<unsigned long long>
- [ ] std::atomic<char8_t>
- [ ] std::atomic<char16_t>
- [ ] std::atomic<char32_t>
- [ ] std::atomic<int8_t>
- [ ] std::atomic<uint8_t>
- [ ] std::atomic<int16_t>
- [ ] std::atomic<uint16_t>
- [ ] std::atomic<int32_t>
- [ ] std::atomic<uint32_t>
- [ ] std::atomic<int64_t>
- [ ] std::atomic<uint64_t>
- [ ] std::atomic<int_least8_t>
- [ ] std::atomic<uint_least8_t>
- [ ] std::atomic<int_least16_t>
- [ ] std::atomic<uint_least16_t>
- [ ] std::atomic<int_least32_t>
- [ ] std::atomic<uint_least32_t>
- [ ] std::atomic<int_least64_t>
- [ ] std::atomic<uint_least64_t>
- [ ] std::atomic<int_fast8_t>
- [ ] std::atomic<uint_fast8_t>
- [ ] std::atomic<int_fast16_t>
- [ ] std::atomic<uint_fast16_t>
- [ ] std::atomic<int_fast32_t>
- [ ] std::atomic<uint_fast32_t>
- [ ] std::atomic<int_fast64_t>
- [ ] std::atomic<uint_fast64_t>
- [ ] std::atomic<intptr_t>
- [ ] std::atomic<uintptr_t>
- [ ] std::atomic<size_t>
- [ ] std::atomic<ptrdiff_t>
- [ ] std::atomic<intmax_t>
- [ ] std::atomic<uintmax_t>
- [ ] std::complex<float> - \* 2
- [ ] std::complex<double> - \* 2
- [ ] std::complex<long double> - \* 2
- [ ] std::bfloat16_t - \* 4
- [ ] std::float16_t - \* 3
- [ ] std::float32_t - \* 3
- [ ] std::float64_t - \* 3
- [ ] std::float128_t - \* 3

## C

- [ ] atomic_bool
- [ ] atomic_char
- [ ] atomic_schar
- [ ] atomic_uchar
- [ ] atomic_short
- [ ] atomic_int
- [ ] atomic_uint
- [ ] atomic_long
- [ ] atomic_ulong
- [ ] atomic_llong
- [ ] atomic_ullong
- [ ] atomic_char8_t
- [ ] atomic_char16_t
- [ ] atomic_char32_t
- [ ] atomic_int8_t
- [ ] atomic_uint8_t
- [ ] atomic_int16_t
- [ ] atomic_uint16_t
- [ ] atomic_int32_t
- [ ] atomic_uint32_t
- [ ] atomic_int64_t
- [ ] atomic_uint64_t
- [ ] atomic_int_least8_t
- [ ] atomic_uint_least8_t
- [ ] atomic_int_least16_t
- [ ] atomic_uint_least16_t
- [ ] atomic_int_least32_t
- [ ] atomic_uint_least32_t
- [ ] atomic_int_least64_t
- [ ] atomic_uint_least64_t
- [ ] atomic_int_fast8_t
- [ ] atomic_uint_fast8_t
- [ ] atomic_int_fast16_t
- [ ] atomic_uint_fast16_t
- [ ] atomic_int_fast32_t
- [ ] atomic_uint_fast32_t
- [ ] atomic_int_fast64_t
- [ ] atomic_uint_fast64_t
- [ ] atomic_intptr_t
- [ ] atomic_uintptr_t
- [ ] atomic_size_t
- [ ] atomic_ptrdiff_t
- [ ] atomic_intmax_t
- [ ] atomic_uintmax_t
- [ ] _Atomic bool
- [ ] _Atomic char
- [ ] _Atomic signed char
- [ ] _Atomic unsigned char
- [ ] _Atomic short
- [ ] _Atomic int
- [ ] _Atomic unsigned int
- [ ] _Atomic long
- [ ] _Atomic unsigned long
- [ ] _Atomic long long
- [ ] _Atomic unsigned long long
- [ ] _Atomic char8_t
- [ ] _Atomic char16_t
- [ ] _Atomic char32_t
- [ ] _Atomic int8_t
- [ ] _Atomic uint8_t
- [ ] _Atomic int16_t
- [ ] _Atomic uint16_t
- [ ] _Atomic int32_t
- [ ] _Atomic uint32_t
- [ ] _Atomic int64_t
- [ ] _Atomic uint64_t
- [ ] _Atomic int_least8_t
- [ ] _Atomic uint_least8_t
- [ ] _Atomic int_least16_t
- [ ] _Atomic uint_least16_t
- [ ] _Atomic int_least32_t
- [ ] _Atomic uint_least32_t
- [ ] _Atomic int_least64_t
- [ ] _Atomic uint_least64_t
- [ ] _Atomic int_fast8_t
- [ ] _Atomic uint_fast8_t
- [ ] _Atomic int_fast16_t
- [ ] _Atomic uint_fast16_t
- [ ] _Atomic int_fast32_t
- [ ] _Atomic uint_fast32_t
- [ ] _Atomic int_fast64_t
- [ ] _Atomic uint_fast64_t
- [ ] _Atomic intptr_t
- [ ] _Atomic uintptr_t
- [ ] _Atomic size_t
- [ ] _Atomic ptrdiff_t
- [ ] _Atomic intmax_t
- [ ] _Atomic uintmax_t
- [ ] float _Complex - \* 2
- [ ] _Complex float - \* 2
- [ ] complex float - \* 2
- [ ] double _Complex - \* 2
- [ ] _Complex double - \* 2
- [ ] complex double - \* 2
- [ ] long double _Complex - \* 2
- [ ] _Complex long double - \* 2
- [ ] long _Complex double - \* 2
- [ ] long double complex - \* 2
- [ ] complex long double - \* 2
- [ ] long complex double - \* 2
- [ ] _Decimal32 - \* 5
- [ ] _Decimal64 - \* 5
- [ ] _Decimal128 - \* 5
- [ ] _Float16 - \* 3
- [ ] _Float32 - \* 3
- [ ] _Float64 - \* 3
- [ ] _Float128 - \* 3

## Notes

\* 1 - These types are the same as the normal standard library types, but they
use a so-called polymorphic allocator. This allows them to not change the type
of the structure when changing an allocator, since normal types need you to
provide an allocator as a template argument(which is just set to the standard
allocator by default). Source: <https://stackoverflow.com/questions/38010544/polymorphic-allocator-when-and-why-should-i-use-it>

\* 2 - Complex numbers floats are actually an array of 2 floats, that where
the first float is the real value and the second is the imaginary part. Source:
<https://learn.microsoft.com/en-us/cpp/standard-library/complex-float?view=msvc-170>

\* 3 - Read more here: <https://en.wikipedia.org/wiki/IEEE_754>

\* 4 - Learn more about the format: <https://en.wikipedia.org/wiki/Bfloat16_floating-point_format>

\* 5 - Learn more here: <https://en.wikipedia.org/wiki/Decimal32_floating-point_format>
<https://en.wikipedia.org/wiki/Decimal64_floating-point_format>
<https://en.wikipedia.org/wiki/Decimal128_floating-point_format>
