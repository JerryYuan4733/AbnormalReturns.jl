struct BasicReg{L,R} <: RegressionModel
    nobs::Int
    formula::FormulaTerm{L,R}
    coef::Vector{Float64}
    coefnames::Vector{String}
    yname::String
    tss::Float64
    rss::Float64
    residuals::Union{Vector{Float64}, Nothing}
    function BasicReg(nobs, formula::FormulaTerm{L,R}, coef, coefnames, yname, tss, rss, residuals) where {L,R}
        # @assert rss >= 0 "Residual sum of squares must be greater than 0"
        # @assert tss >= 0 "Total sum of squares must be greater than 0"
        # @assert nobs >= 0 "Observations must be greater than 0"
        # @assert length(coef) == length(coefnames) "Number of coefficients must be same as number of coefficient names"
        new{L,R}(nobs, formula, coef, coefnames, yname, tss, rss, residuals)
    end
    BasicReg(x::Int, f::FormulaTerm{L,R}) where {L, R} = new{L,R}(x, f)
end

# These are created to minimize the amount of allocations Julia does
# Julia typically allocates a vector for each loop, which when using
# so many loops, can create real garbage collection problems
# As it turns out, doing sum(abs2, resp - mean(resp)) also does
# an allocation, which could mean allocating a huge amount
# caluclating rss was even worse, so these functions are only
# meant to be used internally but do not allocate if passed a view
function calc_tss(resp)
    out = 0.0
    m = mean(resp)
    @simd for x in resp
        out += (x - m) ^ 2
    end
    out
end
function fast_pred(pred, coef, i)
    out = 0.0
    @simd for j in 1:length(coef)
        @inbounds out += pred[i, j] * coef[j]
    end
    out
end
function calc_rss(resp, pred, coef)
    out = 0.0
    @simd for i in 1:length(resp)
        @inbounds out += (resp[i] - fast_pred(pred, coef, i)) ^ 2
    end
    out
end
function BasicReg(
    resp::AbstractVector{Float64},
    pred::AbstractMatrix{Float64},
    yname::String,
    xnames::Vector{String},
    f::FormulaTerm{L,R};
    save_residuals=false,
    minobs::Int=1
)::BasicReg{L,R} where {L,R}
    if length(resp) <= size(pred, 2) || length(resp) < minobs
        return BasicReg(length(resp), f)
    end

    coef = cholesky!(Symmetric(pred' * pred)) \ (pred' * resp)

    BasicReg(
        length(resp),
        f,
        coef,
        xnames,
        yname,
        calc_tss(resp),
        calc_rss(resp, pred, coef),
        save_residuals ? resp - pred * coef : nothing
    )
end

function create_pred_matrix(data::TimelineTable{true}, sch)
    # This allows missing to make sure all dates are in the data
    # it is not necessary to include missing bdays since the
    # timelinetable already has the same information

    mat = modelcols(sch.rhs, data)
    DataMatrix(
        mat,
        data_dates(data),
        calendar(data)
    )
end


function quick_reg(
    data::TimelineTable{false},# only works if no missing data for multiplication
    f::FormulaTerm{L,R};
    minobs::V=0.8,
    save_residuals::Bool=false
) where {L,R,V<:Real}

    minobs = if minobs < 1
        Int(floor((bdayscount(data.calendar, dt_min(data), dt_max(data)) + 1) * minobs))
    else
        Int(floor(minobs))
    end

    if !StatsModels.omitsintercept(f) & !StatsModels.hasintercept(f)
        f = FormulaTerm(f.lhs, InterceptTerm{true}() + f.rhs)
    end
    sch = apply_schema(f, schema(f, data))
    select!(data, internal_termvars(sch))

    
    resp, pred = modelcols(sch, data)
    yname, xnames = coefnames(sch)
    BasicReg(
        resp,
        pred,
        yname,
        xnames,
        f;
        save_residuals,
        minobs
    )
end

function fill_vector_reg(
    parent_data::MarketData{T},
    iters::Dict{T, Vector{IterateOutput}},
    out_vector::Vector{BasicReg{L,R}},
    cache::DataMatrix,
    sch::FormulaTerm{L2,R2},
    f::FormulaTerm{L,R};
    save_residuals::Bool=false
) where {T, L, R, L2, R2}
    @assert validate_iterator(iters, out_vector) "Length of out_vector does not match the number of indexes in the iterator"
    cols = internal_termvars(sch)
    yname, xnames = coefnames(sch)
    
    Threads.@threads for u_id in keys(iters) |> collect
        data = parent_data[u_id, cols, AllowMissing{true}]
        resp = datavector_modelcols(int_lhs(sch), data)
        for iter in iters[u_id]
            cur_dates = dates_min_max(data_dates(data), iter_dates(iter))
            if nnz(data_missing_bdays(data)) == 0
                x = view(resp, cur_dates)
                y = view(cache, cur_dates)
            else
                new_mssngs = get_missing_bdays(data, cur_dates)
                x = view(resp, cur_dates, new_mssngs)
                y = view(cache, cur_dates, new_mssngs)
            end
            @inbounds out_vector[iter_index(iter)] = BasicReg(
                x,
                y,
                yname,
                xnames,
                f;
                save_residuals,
                minobs=iter_minobs(iter)
            )
        end
    end
    out_vector
end

function vector_reg(
    parent_data::MarketData{T},
    ids::AbstractVector{T},
    date_mins::AbstractVector{Date},
    date_maxs::AbstractVector{Date},
    f::FormulaTerm{L,R};
    minobs::V=0.8,
    save_residuals::Bool=false
) where {T,L,R,V<:Real}
    if !StatsModels.omitsintercept(f) & !StatsModels.hasintercept(f)
        f = FormulaTerm(f.lhs, InterceptTerm{true}() + f.rhs)
    end
    sch = apply_schema(f, schema(f, parent_data))
    cache = create_pred_matrix(
        parent_data[ids[1], internal_termvars(sch.rhs), AllowMissing{true}],
        sch
    )
    out = fill(BasicReg(0, f), length(ids))
    iter_dict = construct_id_dict(ids, date_mins, date_maxs, calendar(parent_data); minobs)
    fill_vector_reg(
        parent_data,
        iter_dict,
        out,
        cache,
        sch,
        f;
        save_residuals
    )
end


"""

    cache_reg(
        id::Int,
        est_min::Date,
        est_max::Date;
        cols_market::Union{Nothing, Vector{String}}=nothing,
        col_firm::String="ret",
        minobs=.8,
        calendar="CrspMarketCalendar"
    )

An intentionally minamilistic linear regression of a vector of firm data on a matrix
of market data, where the firm data is provided by an Integer id and the range
of dates. Designed to quickly estimate Fama French predicted returns.

## Arguments

- `id::Int`: The firm identifier
- `est_min::Date`: The start of the estimation period
- `est_max::Date`: The end of the estimation period
- `cols_market::Union{Nothing, Vector{String}}=nothing`: A vector of columns that are stored
    in the MARKET_DATA_CACHE, should not be repeated and it is recommended to include `"intercept"`
    as the intercept (typically first). If `nothing` (default) then all columns saved will be used.
    Note that if all columns are used there could be errors in the regression (if the risk free rate
    is stored) since over short periods the risk free rate is often constant and conflicts with
    the intercept
- `col_firm::String="ret"`: The column for the firm vector, typically this is the return, it must be
    in the FIRM_DATA_CACHE data
- `minobs=.8`: Minimum number of observations to run the regression, if the number provided
    is less than 1, then it is assumed to be a ratio (i.e., minimum observations is number of
    businessdays times minobs)
- `calendar="CrspMarketCalendar"`: calendar to use if minobs is less than 1, should be initialized cache if
    used.
- `save_residuals::Bool=false`: Whether or not to save the residuals in the regression
"""

StatsBase.predict(mod::BasicReg, x) = x * coef(mod)

StatsBase.coef(x::BasicReg) = isdefined(x, :coef) ? x.coef : missing
StatsBase.coefnames(x::BasicReg) = isdefined(x, :coef) ? x.coefnames : missing
StatsBase.responsename(x::BasicReg) = isdefined(x, :coef) ? x.yname : missing
StatsBase.nobs(x::BasicReg) = x.nobs
StatsBase.dof_residual(x::BasicReg) = isdefined(x, :coef) ? nobs(x) - length(coef(x)) : missing
StatsBase.r2(x::BasicReg) = 1 - (rss(x) / deviance(x))
StatsBase.adjr2(x::BasicReg) = 1 - rss(x) / deviance(x) * (nobs(x) - 1) / dof_residual(x)
StatsBase.islinear(x::BasicReg) = true
StatsBase.deviance(x::BasicReg) = isdefined(x, :coef) ? x.tss : missing
StatsBase.rss(x::BasicReg) = isdefined(x, :coef) ? x.rss : missing
function StatsBase.residuals(x::BasicReg)
    if x.residuals === nothing
        @error("To access residuals, run `cache_reg` with the option `save_residuals=true`")
    else
        x.residuals
    end
end

"""
    predict(rr::RegressionModel, date_start::Date, date_end::Date)

Uses a provided RegressionModel model and the cached saved market data to predict returns
between the two dates provided.

This will work with any RegressionModel provided as long as it provides methods for `coefnames`
that correspond to names stored in the MARKET_DATA_CACHE and a `coef` method. The model should be linear.
"""
# # this might be too generalized...
# function StatsBase.predict(rr::RegressionModel, data::TimelineTable{false})
#     f = rr.formula
#     select!(data, internal_termvars(f))
    

#     # a Schema is normally built by running schema(f, data)
#     # but doing that repeatedly is quite slow and, in this case, does not
#     # provide any extra use since all of the columns are already known to be continuous
#     # and the other values (mean, var, min, max) are not used later
#     sch = apply_schema(f, schema(f, data))

#     pred = modelcols(sch.rhs, data)
#     predict(rr, pred)
# end

function rhs_str(nms, vals; intercept = "(Intercept)")
    out = String[]
    for (nm, val) in zip(nms, vals)
        val_str = string(round(val, digits=3))
        if nm == intercept
            push!(out, val_str)
        else
            push!(out, val_str * "*" * nm)
        end
    end
    join(out, " + ")
end

function Base.show(io::IO, rr::BasicReg)
    if !isdefined(rr, :coef)
        print(io, "Obs: $(nobs(rr)), $(rr.formula)")
    else
        print(io, "Obs: $(nobs(rr)), $(responsename(rr)) ~ $(rhs_str(coefnames(rr), coef(rr))), AdjR2: ", round(adjr2(rr) * 100, digits=3), "%")
        # mat = hcat(
        #     coefnames(rr),
        #     string.(round.(coef(rr), digits=3))
        # )
        # PrettyTables.pretty_table(io, mat)
    end
end