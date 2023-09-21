# Enable CUDA/AMDGPU if the required packages are installed or in any case (enables to use the package for CPU-only without requiring the CUDA/AMDGPU packages functional - or even not at all if the installation procedure allows it). NOTE: it cannot be precompiled for GPU on a node without GPU.
import .ParallelKernel: ENABLE_CUDA, ENABLE_AMDGPU  # ENABLE_CUDA and ENABLE_AMDGPU must also always be accessible from the unit tests
@static if ENABLE_CUDA && ENABLE_AMDGPU
    using CUDA
    using AMDGPU
elseif ENABLE_CUDA 
    using CUDA
elseif ENABLE_AMDGPU
    using AMDGPU
end
import MacroTools: @capture, postwalk, splitarg # NOTE: inexpr_walk used instead of MacroTools.inexpr
import .ParallelKernel: eval_arg, split_args, split_kwargs, extract_posargs_init, extract_kernel_args, insert_device_types, is_kernel, is_call, gensym_world, isgpu, @isgpu, substitute, inexpr_walk, add_inbounds, cast, @ranges, @rangelengths, @return_value, @return_nothing
import .ParallelKernel: PKG_CUDA, PKG_AMDGPU, PKG_THREADS, PKG_NONE, NUMBERTYPE_NONE, SUPPORTED_NUMBERTYPES, SUPPORTED_PACKAGES, ERRMSG_UNSUPPORTED_PACKAGE, INT_CUDA, INT_AMDGPU, INT_THREADS, INDICES, PKNumber, RANGES_VARNAME, RANGES_TYPE, RANGELENGTH_XYZ_TYPE, RANGELENGTHS_VARNAMES, THREADIDS_VARNAMES, GENSYM_SEPARATOR, AD_SUPPORTED_ANNOTATIONS
import .ParallelKernel: @require, @symbols, symbols, longnameof, @prettyexpand, @prettystring, prettystring, @gorgeousexpand, @gorgeousstring, gorgeousstring


## CONSTANTS

const WITHIN_DOC = """
    @within(macroname::String, A)

Return an expression that evaluates to `true` if the indices generated by @parallel (module ParallelStencil) point to elements in bounds of the selection of `A` by `macroname`.

!!! warning
    This macro is not intended for explicit manual usage. Calls to it are automatically added by @parallel where required.
"""

const SUPPORTED_NDIMS           = [1, 2, 3]
const NDIMS_NONE                = 0
const ERRMSG_KERNEL_UNSUPPORTED = "unsupported kernel statements in @parallel kernel definition: @parallel is only applicable to kernels that contain exclusively array assignments using macros from FiniteDifferences{1|2|3}D or from another compatible computation submodule. @parallel_indices supports any kind of statements in the kernels."
const ERRMSG_CHECK_NDIMS        = "ndims must be noted LITERALLY (NOT a variable containing the ndims) and has to be one of the following: $(join(SUPPORTED_NDIMS,", "))"
const ERRMSG_CHECK_MEMOPT       = "memopt must be a evaluatable at parse time (e.g. literal or constant) and has to be of type Bool."
const PSNumber                  = PKNumber
const LOOPSIZE                  = 16
const LOOPDIM_NONE              = 0
const NTHREADS_MAX_LOOPOPT      = 128
const USE_SHMEMHALO_DEFAULT     = true
const USE_SHMEMHALO_1D_DEFAULT  = true
const USE_FULLRANGE_DEFAULT     = (false, false, true)
const FULLRANGE_THRESHOLD       = 1
const NOEXPR                    = :(begin end)
const MOD_METADATA              = :__metadata__ # gensym_world("__metadata__", @__MODULE__) # # TODO: name mangling should be used here later, or if there is any sense to leave it like that then at check whether it's available must be done before creating it
const META_FUNCTION_PREFIX      = string(gensym_world("META", @__MODULE__))


## FUNCTIONS TO DEAL WITH KERNEL DEFINITIONS

get_statements(body::Expr)     = (body.head == :block) ? body.args : [body]
is_array_assignment(statement) = isa(statement, Expr) && (statement.head == :(=)) && isa(statement.args[1], Expr) && (statement.args[1].head == :macrocall)

function validate_body(body::Expr)
    statements = get_statements(body)
    for statement in statements
        if !(isa(statement, LineNumberNode) || isa(statement, Expr)) @ArgumentError(ERRMSG_KERNEL_UNSUPPORTED) end
        if isa(statement, Expr) && !is_array_assignment(statement)   @ArgumentError(ERRMSG_KERNEL_UNSUPPORTED) end
    end
end

is_stencil_access(ex::Expr, ix::Symbol, iy::Symbol, iz::Symbol) = @capture(ex, A_[x_, y_, z_]) && inexpr_walk(x, ix) && inexpr_walk(y, iy) && inexpr_walk(z, iz)
is_stencil_access(ex::Expr, ix::Symbol, iy::Symbol)             = @capture(ex, A_[x_, y_])     && inexpr_walk(x, ix) && inexpr_walk(y, iy)
is_stencil_access(ex::Expr, ix::Symbol)                         = @capture(ex, A_[x_])         && inexpr_walk(x, ix)
is_stencil_access(ex, indices...)                               = false

function substitute(expr::Expr, A, m, indices::NTuple{N,<:Union{Symbol,Expr}} where N)
    return postwalk(expr) do ex
        if is_stencil_access(ex, indices...)
            @capture(ex, B_[indices_expr__]) || @ModuleInternalError("a stencil access could not be pattern matched.")
            if B == A
                m_call = :(@f($(indices_expr...))) # NOTE: interpolating the macro symbol m directly does not work
                m_call.args[1] = Symbol("@$m")
                return m_call
            else
                return ex
            end
        else
            return ex
        end
    end
end


## FUNCTIONS AND MACROS FOR USAGE IN CUSTOM MACRO DEFINITIONS

function expandargs(caller, args...; valid_types::NTuple{N,Type}=(Symbol, Expr)) where N
    for arg in args
        if (typeof(arg) ∉ valid_types) @ArgumentError("argument $arg is not of type $(join(valid_types, ", ", " or ")).") end
    end
    args = macroexpand.((caller,), args)
    return args
end


## FUNCTIONS FOR ERROR HANDLING

check_ndims(ndims)     = ( if !isa(ndims, Integer) || !(ndims in SUPPORTED_NDIMS) @ArgumentError("$ERRMSG_CHECK_NDIMS (obtained: $ndims)." ) end )
check_memopt(memopt) = ( if !isa(memopt, Bool) @ArgumentError("$ERRMSG_CHECK_MEMOPT (obtained: $memopt)." ) end )