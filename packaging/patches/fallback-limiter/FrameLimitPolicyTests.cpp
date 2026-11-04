#include "FrameLimitPolicy.h"
#include <cmath>
#include <cstdint>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string>

static unsigned checks = 0;
static void Equal(std::uint64_t actual, std::uint64_t expected, const char* label)
{
    ++checks;
    if (actual != expected)
        throw std::runtime_error(std::string(label) + ": got " + std::to_string(actual) +
                                 ", expected " + std::to_string(expected));
}
int main()
{
    try
    {
        using namespace FrameLimitPolicy;
        Equal(OutputMultiplier(false, 0), 1, "inactive");
        Equal(OutputMultiplier(false, 4), 1, "inactive/paused ignores retained count");
        Equal(OutputMultiplier(false, UINT32_MAX), 1, "inactive ignores invalid retained count");
        Equal(OutputMultiplier(true, 0), 1, "zero generated frames");
        Equal(OutputMultiplier(true, UINT32_MAX), 4294967296ULL, "count addition does not wrap");
        const std::uint64_t expected240[] = {4166, 8333, 12500, 16666, 20833, 25000};
        const std::uint64_t expected223[] = {4466, 8932, 13398, 17865, 22331, 26797};
        for (std::uint32_t generated = 0; generated < 6; ++generated)
        {
            const auto multiplier = OutputMultiplier(true, generated);
            Equal(multiplier, std::uint64_t(generated) + 1, "fixed multiplier1x..6x");
            Equal(MinimumIntervalUs(240.0f, multiplier), expected240[generated], "240 output FPS");
            Equal(MinimumIntervalUs(223.900009f, multiplier), expected223[generated], "fractional output cap");
        }
        Equal(MinimumIntervalUs(223.900009f, OutputMultiplier(false, 4)), 4466, "paused returns1x");
        Equal(MinimumIntervalUs(223.900009f, OutputMultiplier(true, 4)), 22331, "unpaused5x");
        Equal(MinimumIntervalUs(223.900009f, OutputMultiplier(true, 1)), 8932, "live change5x to2x");
        Equal(MinimumIntervalUs(120.0f, 4), 33333, "cap change120");
        Equal(MinimumIntervalUs(240.0f, 4), 16666, "cap change240");
        Equal(MinimumIntervalUs(0.0f, 5), 0, "cap disabled");
        Equal(MinimumIntervalUs(-0.0f, 5), 0, "negative zero disabled");
        Equal(MinimumIntervalUs(-60.0f, 5), 0, "negative cap rejected");
        Equal(MinimumIntervalUs(std::numeric_limits<float>::quiet_NaN(), 5), 0, "NaN rejected");
        Equal(MinimumIntervalUs(std::numeric_limits<float>::infinity(), 5), 0, "infinity rejected");
        Equal(MinimumIntervalUs(-std::numeric_limits<float>::infinity(), 5), 0, "negative infinity rejected");
        Equal(MinimumIntervalUs(240.0f, 0), 4166, "zero multiplier normalized");
        Equal(MinimumIntervalUs(std::numeric_limits<float>::denorm_min(), UINT64_MAX), 100000000, "clamp before integer conversion");
        Equal(MinimumIntervalUs(0.01f, 6), 100000000, "total interval bounded");
        Equal(MinimumIntervalUs(std::numeric_limits<float>::max(), 1), 0, "sub-microsecond interval");
        std::cout << checks << " production-policy checks passed; no game, GPU, timer or runtime DLL used.\n";
        return 0;
    }
    catch (const std::exception& error)
    {
        std::cerr << error.what() << '\n';
        return 1;
    }
}