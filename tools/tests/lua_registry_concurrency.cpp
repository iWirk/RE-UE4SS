#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <array>
#include <barrier>
#include <cstdio>
#include <stdexcept>
#include <thread>
#include <unordered_set>
#include <vector>

using RC::LuaMadeSimple::Lua;

static void require(bool condition, const char* message)
{
    if (!condition) throw std::runtime_error(message);
}

static int callback(lua_State* state)
{
    lua_pushvalue(state, lua_upvalueindex(1));
    return 1;
}

static void push_callback(const Lua& lua, int token)
{
    lua_pushinteger(lua.get_lua_state(), token);
    lua_pushcclosure(lua.get_lua_state(), callback, 1);
}

static void check_callback(const Lua& lua, int ref, int token)
{
    lua.registry().get_function_ref(ref);
    lua.call_function(0, 1);
    require(lua_isinteger(lua.get_lua_state(), -1) && lua_tointeger(lua.get_lua_state(), -1) == token,
            "Live callback reference was overwritten");
    lua_pop(lua.get_lua_state(), 1);
}

// The same registry is shared by the independently owned coroutine stacks.
static void test_concurrent_refs(const Lua& first, const Lua& second)
{
    constexpr int count = 20000;
    constexpr int rounds = 50;
    constexpr int batch = 128;
    const Lua* workers[]{&first, &second};
    std::vector<int> refs[2];
    std::exception_ptr failures[2];
    std::barrier start(2);
    auto allocate = [&](int index) {
        try
        {
            const auto& lua = *workers[index];
            refs[index].reserve(count);
            start.arrive_and_wait();
            for (int i = 0; i < count; ++i)
            {
                push_callback(lua, index * count + i);
                refs[index].push_back(lua.registry().make_ref());
            }
        }
        catch (...) { failures[index] = std::current_exception(); }
    };
    std::thread a(allocate, 0);
    std::thread b(allocate, 1);
    a.join();
    b.join();
    for (auto failure : failures) if (failure) std::rethrow_exception(failure);

    std::unordered_set<int> unique;
    for (int index = 0; index < 2; ++index)
        for (int i = 0; i < count; ++i)
        {
            require(unique.insert(refs[index][i]).second, "Duplicate live registry reference");
            check_callback(*workers[index], refs[index][i], index * count + i);
        }
    std::printf("Concurrent allocation: %zu unique references, callback identities intact\n", unique.size());

    // Seed the free list while retaining callbacks that must survive later reuse.
    for (int index = 0; index < 2; ++index)
        for (int i = 1; i < count; ++i)
            workers[index]->registry().release_ref(refs[index][i]);

    std::array<int, batch> live[2];
    auto churn = [&](int index) {
        start.arrive_and_wait();
        for (int round = 0; round < rounds; ++round)
        {
            // Always reach both barriers, even on failure, so the test cannot strand its peer.
            try
            {
                const auto& lua = *workers[index];
                for (int i = 0; i < batch; ++i)
                {
                    if (index == 0) push_callback(lua, round * batch + i);
                    else lua_pushboolean(lua.get_lua_state(), (round + i) % 2);
                    live[index][i] = lua.registry().make_ref();
                }
            }
            catch (...) { failures[index] = std::current_exception(); }
            start.arrive_and_wait();
            try
            {
                const auto& lua = *workers[index];
                std::unordered_set<int> active{refs[0][0], refs[1][0]};
                for (const auto& list : live)
                    for (int ref : list)
                        require(active.insert(ref).second, "Free-list reuse duplicated a live reference");
                check_callback(lua, refs[index][0], index * count);
                for (int i = 0; i < batch; ++i)
                {
                    if (index == 0) check_callback(lua, live[index][i], round * batch + i);
                    else
                    {
                        require(lua.rawgeti(LUA_REGISTRYINDEX, live[index][i]) == LUA_TBOOLEAN,
                                "Boolean registry reference changed type");
                        require(lua_toboolean(lua.get_lua_state(), -1) == (round + i) % 2,
                                "Boolean registry reference changed value");
                        lua_pop(lua.get_lua_state(), 1);
                    }
                    lua.registry().release_ref(live[index][i]);
                }
                require(lua.get_stack_size() == 0, "Registry operations left values on the stack");
            }
            catch (...) { failures[index] = std::current_exception(); }
            start.arrive_and_wait();
        }
    };
    std::thread c(churn, 0);
    std::thread d(churn, 1);
    c.join();
    d.join();
    for (auto failure : failures) if (failure) std::rethrow_exception(failure);
    for (int index = 0; index < 2; ++index) workers[index]->registry().release_ref(refs[index][0]);
    std::printf("Concurrent free-list reuse: %d mixed function/boolean references, no corruption\n", rounds * batch * 2);

    auto recycle = [&](int index) {
        start.arrive_and_wait();
        try
        {
            const auto& lua = *workers[index];
            for (int i = 0; i < count; ++i)
            {
                push_callback(lua, index * count + i);
                const int ref = lua.registry().make_ref();
                check_callback(lua, ref, index * count + i);
                lua.registry().release_ref(ref);
            }
        }
        catch (...) { failures[index] = std::current_exception(); }
    };
    std::thread e(recycle, 0);
    std::thread f(recycle, 1);
    e.join();
    f.join();
    for (auto failure : failures) if (failure) std::rethrow_exception(failure);
    std::printf("Overlapping allocation/release: %d callbacks retained their identity\n", count * 2);
}

static void test_caller_stack_refs(const Lua& caller, const Lua& hook)
{
    auto* state = caller.get_lua_state();
    push_callback(caller, 17);
    push_callback(caller, 29);
    lua_pushinteger(hook.get_lua_state(), 12345);
    const int pre = caller.registry().make_ref(1);
    const int post = caller.registry().make_ref(-1);
    require(lua_gettop(state) == 2 && lua_isfunction(state, 1) && lua_isfunction(state, 2),
            "Indexed make_ref consumed or changed its arguments");
    require(hook.get_stack_size() == 1 && lua_tointeger(hook.get_lua_state(), 1) == 12345,
            "Registration changed the hook stack");
    lua_settop(state, 0);
    check_callback(hook, pre, 17);
    check_callback(hook, post, 29);
    caller.registry().release_ref(pre);
    hook.registry().release_ref(post);
    lua_pop(hook.get_lua_state(), 1);
    lua_pushnil(state);
    require(caller.registry().make_ref() == LUA_REFNIL, "Nil reference did not return LUA_REFNIL");
    caller.registry().release_ref(LUA_REFNIL);
    caller.registry().release_ref(LUA_NOREF);
    require(caller.get_stack_size() == 0 && hook.get_stack_size() == 0, "Unbalanced callback registration stacks");
    std::puts("Caller-stack registration: shared callbacks callable, arguments and hook stack preserved");
}

int main()
{
    try
    {
        auto& root = RC::LuaMadeSimple::new_state();
        auto& first = root.new_thread();
        const int first_anchor = root.registry().make_ref();
        auto& second = root.new_thread();
        const int second_anchor = root.registry().make_ref();
        test_concurrent_refs(first, second);
        test_caller_stack_refs(first, second);
        lua_gc(root.get_lua_state(), LUA_GCCOLLECT);
        require(root.rawgeti(LUA_REGISTRYINDEX, first_anchor) == LUA_TTHREAD, "First coroutine anchor was lost");
        require(lua_tothread(root.get_lua_state(), -1) == first.get_lua_state(), "First coroutine anchor changed");
        lua_pop(root.get_lua_state(), 1);
        require(root.rawgeti(LUA_REGISTRYINDEX, second_anchor) == LUA_TTHREAD, "Second coroutine anchor was lost");
        require(lua_tothread(root.get_lua_state(), -1) == second.get_lua_state(), "Second coroutine anchor changed");
        lua_pop(root.get_lua_state(), 1);
        lua_close(root.get_lua_state());
        std::puts("PASS");
        return 0;
    }
    catch (const std::exception& error)
    {
        std::fprintf(stderr, "FAIL: %s\n", error.what());
        return 1;
    }
}
