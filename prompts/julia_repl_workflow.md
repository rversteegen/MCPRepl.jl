# Julia REPL Workflow

## Quick Start
Use `exec_repl` for Julia development. If the REPL tool doesn't work when you try to use it, consider asking the user to fix it instead of running julia via bash.

## Best Practices ✅

### Variable Management
Use `let` blocks for temporary computations to avoid cluttering global scope:

```julia
let x = 10, y = 20
    result = x + y
end
```

### Testing
Use targeted approaches:

```julia
@test my_function(1) == 2
@test_throws ArgumentError my_function(-1)

# Interactive testing
let test_input = [1, 2, 3]
    result = my_function(test_input)
    @show result
end
```

### Documentation
**Check documentation before using unfamiliar functions:**

```julia
@doc function_name      # Function documentation
@doc String             # Type documentation
names(PackageName)      # List package contents
@which sort([1,2,3])    # Method inspection
methods(sort)           # All methods
methodswith(String)     # Methods with specific type
```

## What NOT TO DO ❌

- **Don't install packages yourself** - ask the user to do it (and if you're asked to, always use `add --preserve-all`
- **Don't clutter global scope** - use `let` blocks
- **Don't use `Pkg.test()`** - too slow, ask permission first

## Troubleshooting
If Revise starts erroring or doesn't seem to work:
1. Try using `include()` instead of `includet()`
2. If that's not enough, restart the REPL with the restart_repl tool

## Revise.jl + CodeTracking.jl Integration
Changes to `includet`'ed files are automatically picked up and usually don't need to be re-included.

You can use CodeTracking functions such as whereis, definition, to check what names in scope actually refer to.
