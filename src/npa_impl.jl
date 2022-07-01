Moments = Dict{Monomial}{BlockDiagonal}

function sparse_sym_add!(matrix, i, j, val)
    matrix[i, j] += val

    if i != j
        matrix[j, i] += val
    end
end

function sparse_sym(N, i, j, val)
    if i == j
        return sparse([i], [i], [val], N, N)
    else
        return sparse([i, j], [j, i], [val, val], N, N)
    end
end

function npa_moments_block(operators)
    N = length(operators)
    iops = collect(enumerate(operators))
    block = Dict{Monomial,SparseMatrixCSC}()

    for (i, x) in iops
        for (j, y) in iops[i:end]
            p = Polynomial(conj_min(conj(x)*y))

            for (c, m) in p
                if !haskey(block, m)
                    block[m] = sparse_sym(N, i, j, c)
                else
                    sparse_sym_add!(block[m], i, j, c)
                end
            end
        end
    end

    return block
end

"""
Construct the NPA moment matrix.

The argument operators can in general be an array of arrays of operators
(blocks), e.g. [[Id], [A1 + B1], [A1 - B1]]. It can also be a simple array of
operators, in which case it is treated the same as an array containing a
single array of operators, e.g., [[Id, A1, A2]]). In either case the return
value is a dictionary with:

  * as keys: monomials obtained by multiplying operators in the same blocks
    together.

  * as values: block-diagonal sparse matrices with coefficients obtained
    from multiplying the input operators together.
"""
function npa_moments(operators)
    if isempty(operators)
        return moments
    end

    if first(operators) isa Union{Number,Monomial,Polynomial}
        operators = [operators]
    end

    nblocks = length(operators)
    bsizes = length.(operators)
    blocks = npa_moments_block.(operators)

    ms = monomials(keys(block) for block in blocks)

    moments = Moments()

    for m in ms
        blocks_m = [(haskey(block, m)
                     ? block[m]
                     : (n -> spzeros(n, n))(bsizes[b]))
                    for (b, block) in enumerate(blocks)]

        moments[m] = BlockDiagonal(blocks_m)
    end

    return moments
end



function SparseArrays.dropzeros!(matrix::BlockDiagonal)
    for blk in blocks(matrix)
        dropzeros!(blk)
    end

    return matrix
end

"""
Generate the NPA relaxation for a given quantum optimisation problem (an
operator expr whose expectation we want to maximise with the expectation
values of the operators constraints set to zero).
"""
function npa2sdp(expr,
                 constraints,
                 moments::Moments)
    # Reduce constraints to canonical form

    expr = conj_min(expr)
    constraints = linspace(map(conj_min, constraints))

    if haskey(constraints, Id)
        @error "Contradiction Id = 0 in constraints."
    end

    # Reduce the objective expression, using constraints to eliminate
    # monomials
    expr = reduce_expr(expr, constraints)
    moments = deepcopy(moments)

    for (m0, constraint) in constraints
        q = constraint[m0]
        constraint[m0] = 0

        moment0 = moments[m0]
        delete!(moments, m0)

        for (c, m) in constraint
            moments[m] -= rdiv(c, q) * moment0
        end
    end

    # Remove any zero coefficients that might be stored explicitly in the
    # sparse matrices in the blocks.
    # for matrix in values(moments)
    #    dropzeros!(matrix)
    # end
    
    moments = Moments(m => mat
                      for (m, mat) in moments
                          if !iszero(mat))

    return (expr, moments)
end

function npa2sdp(expr,
                 constraints,
                 level)
    monomials = ops_at_level([expr, constraints], level)

    return npa2sdp(expr,
                   constraints,
                   npa_moments(monomials))
end

npa2sdp(expr, lvl_or_constraints) = npa2sdp(expr, [], lvl_or_constraints)



function SparseArrays.findnz(mat::BlockDiagonal)
    base = 0

    is = Int[]
    js = Int[]
    cs = []

    for blk in blocks(mat)
        (is1, js1, cs1) = findnz(blk)
        append!(is, is1 .+ base)
        append!(js, js1 .+ base)
        append!(cs, cs1)
        base += first(size(mat))
    end

    return (is, js, cs)
end

function firstnz(moment::BlockDiagonal)
    base = 0

    for blk in blocks(moment)
        if !iszero(blk)
            (i, j, c) = first((i, j, c)
                              for (i, j, c) in zip(findnz(blk)...))
            @assert !iszero(c)

            if (i > j)
                (i, j) = (j, i)
            end
            
            return (i + base, j + base, c)
        else
            base += first(size(blk))
        end
    end
end


function bspzeros(bsizes)
    return BlockDiagonal([spzeros(Number, n, n)
                          for n in bsizes])
end

function Base.zero(bm::BlockDiagonal)
    return bspzeros(first.(blocksizes(bm)))
end

"""
Return upper triangular indices of blocks in a block diagonal matrix with
blocks of size bsizes.
"""
function butindices(bsizes)
    indices = Set{Tuple{Int,Int}}()

    base = 0

    for bsize in bsizes
        for i in 1:bsize
            for j in i:bsize
                push!(indices, (i + base, j + base))
            end
        end

        base += bsize
    end
    
    return indices
end

function constraint_matrices(moments::Moments)
    @assert(!isempty(moments))

    bsizes = first.(blocksizes(first(values(moments))))

    moments = [copy(moment)
               for (m, moment) in moments
                   if m != Id]

    reduced = Dict{Tuple{Int,Int},BlockDiagonal}()

    # Do the row echelon thing.
    n = length(moments)

    for (k, mat0) in enumerate(moments)
        (i, j, c0) = firstnz(mat0)
        mat0 /= c0

        for l in (k+1):n
            mat = moments[l]
            c = mat[i, j]

            if !iszero(c)
                mat -= rmul(mat0, c)
                mat[i, j] = 0
                mat[j, i] = 0
            end
        end

        reduced[(i, j)] = dropzeros!(mat0)
    end

    indices = utindices(bsizes)
    fixed = Set(keys(reduced))
    other = setdiff(indices, fixed)

    constraints = Set{BlockDiagonal}()

    for (i0, j0) in other
        cstr = bspzeros(bsizes)
        cstr[i0, j0] = 1
        #cstr[j0, i0] = 1

        for ((i, j), gamma) in reduced
            cstr[i, j] = -gamma[i0, j0]
        end

        push!(constraints, cstr)
    end

    return constraints
end



default_solver = SCS.Optimizer

function set_solver(solver)
    global default_solver = solver
end

function set_verbosity!(model, verbose)
    if !isnothing(verbose)
        (!verbose ? set_silent : unset_silent)(model)
    end
end



function expr2objective(expr, vars)
    return expr[Id] + sum(c*vars[m] for (c, m) in expr if m != Id)
end

"""
Convert moments returned by npa2sdp() to moments in a format used by JuMP.jl
or Convex.jl.
"""
function moments2gamma(moments, vars)
    if isempty(moments)
        return []
    end

    n = nblocks(first(moments)[2])
    gamma = Vector(undef, n)

    for (m, moment) in moments
        var = ((m != Id) ? vars[m] : 1)

        for (b, g) in enumerate(blocks(moment))
            if isassigned(gamma, b)
                gamma[b] += g*var
            else
                gamma[b] = g*var
            end
        end
    end

    return gamma
end

"""
Convert an SDP returned by npa2sdp to the JuMP.jl problem format.
"""
function sdp2jump(expr, moments;
                  goal=:maximise,
                  solver=nothing,
                  verbose=nothing)
    model = !isnothing(solver) ? Model(solver) : Model()

    monomials = setdiff(keys(moments), (Id,))

    @variable(model, v[monomials])

    objective = expr2objective(expr, v)
    gamma = moments2gamma(moments, v)

    for g in values(gamma)
        @constraint(model, g >= 0, PSDCone())
    end

    if goal in (:maximise, :maximize, :max)
        @objective(model, Max, objective)
    elseif goal in (:minimise, :minimize, :min)
        @objective(model, Min, objective)
    end

    set_verbosity!(model, verbose)

    return model
end

function sdp2convex(expr, moments;
                    goal=:maximise)
    monomials = setdiff(keys(moments), (Id,))

    v = Dict(m => Variable() for m in monomials)

    objective = expr2objective(expr, v)
    gamma = moments2gamma(moments, v)

    constraints = [(g in :SDP) for g in values(gamma)]

    if goal in (:maximise, :maximize, :max)
        problem = maximize(objective, constraints)
    elseif goal in (:minimise, :minimize, :min)
        problem = minimize(objective, constraints)
    end

    return problem
end



function BlockDiagonals.blocksizes(moments::Moments)
    if isempty(moments)
        return []
    else
        return first.(blocksizes(first(moments)[2]))
    end
end

function sdp2jumpd(expr, moments;
                   goal=:maximise,
                   solver=nothing,
                   verbose=nothing)
    if goal in (:maximise, :maximize, :max)
        maximise = true
        s = 1
    elseif goal in (:minimise, :minimize, :min)
        maximise = false
        s = -1
    end
    
    model = !isnothing(solver) ? Model(solver) : Model()

    Z = [@variable(model, [1:n, 1:n], PSD) for n in blocksizes(moments)]

    objective = (sum(LinearAlgebra.tr(s*G*Z[b])
                     for (b, G) in enumerate(blocks(moments[Id])))
                 + expr[Id])
    
    if maximise
        @objective(model, Min, objective)
    else
        @objective(model, Max, objective)
    end

    for (m, moment) in moments
        if m != Id
            c = expr[m]
            
            @constraint(model,
                        sum(LinearAlgebra.tr(F*Z[b])
                            for (b, F) in enumerate(blocks(moment)))
                        + s*c == 0)
        end
    end

    set_verbosity!(model, verbose)

    return model
end

function sdp2convexd(expr, moments;
                     goal=:maximise,
                     solver=nothing,
                     verbose=nothing)
    if goal in (:maximise, :maximize, :max)
        maximise = true
        s = 1
    elseif goal in (:minimise, :minimize, :min)
        maximise = false
        s = -1
    end
    
    Z = [Semidefinite(bsize) for bsize in blocksizes(moments)]

    objective = (sum(LinearAlgebra.tr(s*G*Z[b])
                     for (b, G) in enumerate(blocks(moments[Id])))
                 + expr[Id])
    
    constraints = [(sum(LinearAlgebra.tr(F*Z[b])
                        for (b, F) in enumerate(blocks(moment)))
                    + s*expr[m] == 0)
                   for (m, moment) in moments if m != Id]

    if maximise
        problem = minimize(objective, constraints)
    else
        problem = maximize(objective, constraints)
    end

    return problem
end



function npa2jump(expr,
                  constraints,
                  level_or_moments;
                  goal=:maximise,
                  solver=nothing,
                  verbose=nothing)
    (expr, moments) = npa2sdp(expr, constraints, level_or_moments)
    model = sdp2jump(expr, moments,
                     goal=goal,
                     solver=solver,
                     verbose=verbose)

    return model
end

function npa2jump(expr, level_or_moments;
                  goal=:maximise,
                  solver=nothing,
                  verbose=nothing)
    return npa2jump(expr, [], level_or_moments,
                    goal=goal,
                    solver=solver,
                    verbose=verbose)
end



function npa2jumpd(expr,
                   constraints,
                   level_or_moments;
                   goal=:maximise,
                   solver=nothing,
                   verbose=nothing)
    (expr, moments) = npa2sdp(expr, constraints, level_or_moments)
    model = sdp2jumpd(expr, moments,
                      goal=goal,
                      solver=solver,
                      verbose=verbose)

    return model
end

function npa2jumpd(expr, level_or_moments;
                   goal=:maximise,
                   solver=nothing,
                   verbose=nothing)
    return npa2jumpd(expr, [], level_or_moments,
                     goal=goal,
                     solver=solver,
                     verbose=verbose)
end



function npa_opt(expr,
                 constraints,
                 level_or_moments;
                 goal=:maximise,
                 solver=default_solver,
                 verbose=false)
    model = npa2jump(expr, constraints, level_or_moments, goal=goal)

    optimise!(model, solver=solver, verbose=verbose)

    return result(model)
end



function optimise!(model::Model; solver=default_solver, verbose=false)
    set_optimizer(model, solver) #, add_bridges=false)

    if !verbose
        set_silent(model)
    end

    optimize!(model)
end

result(model::Model) = objective_value(model)
    


function optimise!(problem::Problem; solver=default_solver, verbose=false)
    solve!(problem, solver, silent_solver=!verbose)
end

result(problem::Problem) = problem.optval



function npa_optd(expr,
                  constraints,
                  level_or_moments;
                  goal=:maximise,
                  solver=default_solver,
                  verbose=false)
    model = npa2jumpd(expr, constraints, level_or_moments, goal=goal)

    set_optimizer(model, solver)

    if !verbose
        set_silent(model)
    end

    optimize!(model)

    return objective_value(model)
end



function npa_max(expr, constraints, level;
                 solver=default_solver,
                 verbose=false)
    return npa_opt(expr, constraints, level,
                   goal=:maximise,
                   solver=solver,
                   verbose=verbose)
end

function npa_max(expr, level; solver=default_solver, verbose=false)
    return npa_max(expr, [], level,
                   solver=solver,
                   verbose=verbose)
end



function npa_maxd(expr, constraints, level;
                  solver=default_solver,
                  verbose=false)
    return npa_optd(expr, constraints, level,
                    goal=:maximise,
                    solver=solver,
                    verbose=verbose)
end

function npa_maxd(expr, level; solver=default_solver, verbose=false)
    return npa_maxd(expr, [], level,
                    solver=solver,
                    verbose=verbose)
end



function npa_min(expr, constraints, level;
                 solver=default_solver,
                 verbose=false)
    return npa_opt(expr, constraints, level,
                   goal=:minimise,
                   solver=solver,
                   verbose=verbose)
end

function npa_min(expr, level; solver=default_solver, verbose=false)
    return npa_min(expr, [], level,
                   solver=solver,
                   verbose=verbose)
end



function npa_mind(expr, constraints, level;
                  solver=default_solver,
                  verbose=false)
    return npa_optd(expr, constraints, level,
                    goal=:minimise,
                    solver=solver,
                    verbose=verbose)
end

function npa_mind(expr, level; solver=default_solver, verbose=false)
    return npa_mind(expr, [], level,
                    solver=solver,
                    verbose=verbose)
end
