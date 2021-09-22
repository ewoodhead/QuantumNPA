#using Printf

abstract type Operator end

# Default multiplication rule for operators, which can be specialised.
#
# Assumption for the moment: multiplication returns a pair
#   (c, [ops...])
# consisting of a coefficient and a possibly empty list of operators.
#
# By default we return c = 1 and a list of the same two operators given as
# inputs, i.e., we just concatenate the operators.
Base.:*(x::Operator, y::Operator) = (1, [x, y])

# This controls how lists of operators are multiplied.
# It is not very general at the moment.
function join_ops(opsx::Array{Operator,1}, opsy::Array{Operator,1})
    opx = opsx[end]
    opy = opsy[1]
    (c, opxy) = opx * opy

    if c == 0
        return (0, [])
    end

    ops = vcat(opsx[1:end-1], opxy, opsy[2:end])

    return (c, ops)
end

Base.show(io::IO, o::Operator) = print_op(io, o)


alphabet = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'I', 'J',
            'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T',
            'U', 'V', 'W', 'X', 'Y', 'Z']

function party2string(p::Int)
    base = length(alphabet)
    chars = Array{Char,1}()

    while (p > 0)
        p -= 1
        push!(chars, alphabet[1 + p % base])
        p = div(p, base)
    end

    return String(reverse!(chars))
end



struct Projector <: Operator
    output::Int
    input::Int
end

function print_op(io::IO, p::Projector, party=nothing)
    if party === nothing
        @printf io "P%d|%d" p.output p.input
    else
        @printf io "P%s%d|%d" party2string(party) p.output p.input
    end
end

function Base.:*(p::Projector, q::Projector)
    if p.input == q.input
        if p.output == q.output
            return (1, [p])
        else
            return (0, Array{Projector}())
        end
    else
        return (1, [p, q])
    end
end

Base.conj(p::Projector) = p



struct Monomial
    word::Array{Tuple{Int,Array{Operator,1}},1}
end

Id = Monomial([])

function Base.show(io::IO, m::Monomial)
    if isempty(m.word)
        print(io, " Id")
    else
        for (party, ops) in m.word
            for o in ops
                print(io, " ")
                print_op(io, o, party)
            end
        end
    end
end

function Base.conj(m::Monomial)
    return Monomial([(party, reverse!([conj(op) for op in ops]))
                     for (party, ops) in m])
end

Base.:*(x::Number, y::Monomial) = Polynomial(x, y)
Base.:*(x::Monomial, y::Number) = Polynomial(y, x)

function Base.:*(x::Monomial, y::Monomial)
    coeff = 1

    M = length(x.word)

    if M == 0
        return y
    end

    N = length(y.word)

    if N == 0
        return x
    end

    j = 1
    k = 1

    word = Array{Tuple{Int,Array{Operator,1}},1}()

    while j <= N && k <= M
        (px, opsx) = x.word[j]
        (py, opsy) = y.word[k]

        if px < py
            push!(word, x.word[j])
            j += 1
        elseif py < px
            push!(word, y.word[k])
            k += 1
        else
            opx = opsx[end]
            opy = opsy[1]
            (c, ops) = join_ops(opsx, opsy)

            if c == 0
                return 0
            end

            coeff *= c

            if !isempty(ops)
                push!(word, (px, ops))
            end

            j += 1
            k += 1
        end
    end

    append!(word, x.word[j:end])
    append!(word, y.word[k:end])

    m = Monomial(word)

    return (coeff = 1) ? m : Polynomial(m, word)
end


function projector(party, output, input)
    return Monomial(1, [(party, [Projector(output, input)])])
end
