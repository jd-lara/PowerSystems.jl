
const POWER_SYSTEM_DESCRIPTOR_FILE =
    joinpath(dirname(pathof(PowerSystems)), "descriptors", "power_system_inputs.json")

const INPUT_CATEGORY_NAMES = [
    ("branch", InputCategory.BRANCH),
    ("bus", InputCategory.BUS),
    ("dc_branch", InputCategory.DC_BRANCH),
    ("gen", InputCategory.GENERATOR),
    ("load", InputCategory.LOAD),
    ("reserves", InputCategory.RESERVE),
    ("storage", InputCategory.STORAGE),
]
struct PowerSystemTableData
    base_power::Float64
    category_to_df::Dict{InputCategory, DataFrames.DataFrame}
    timeseries_metadata_file::Union{String, Nothing}
    directory::String
    user_descriptors::Dict
    descriptors::Dict
    generator_mapping::Dict{NamedTuple, DataType}
end

function PowerSystemTableData(
    data::Dict{String, Any},
    directory::String,
    user_descriptors::Union{String, Dict},
    descriptors::Union{String, Dict},
    generator_mapping::Union{String, Dict};
    timeseries_metadata_file = joinpath(directory, "timeseries_pointers"),
)
    category_to_df = Dict{InputCategory, DataFrames.DataFrame}()

    if !haskey(data, "bus")
        throw(DataFormatError("key 'bus' not found in input data"))
    end

    if !haskey(data, "base_power")
        @warn "key 'base_power' not found in input data; using default=$(DEFAULT_BASE_MVA)"
    end
    base_power = get(data, "base_power", DEFAULT_BASE_MVA)

    for (name, category) in INPUT_CATEGORY_NAMES
        val = get(data, name, nothing)
        if isnothing(val)
            @debug "key '$name' not found in input data, set to nothing" _group =
                IS.LOG_GROUP_PARSING
        else
            category_to_df[category] = val
        end
    end

    if !isfile(timeseries_metadata_file)
        if isfile(string(timeseries_metadata_file, ".json"))
            timeseries_metadata_file = string(timeseries_metadata_file, ".json")
        elseif isfile(string(timeseries_metadata_file, ".csv"))
            timeseries_metadata_file = string(timeseries_metadata_file, ".csv")
        else
            timeseries_metadata_file = nothing
        end
    end

    if user_descriptors isa AbstractString
        user_descriptors = _read_config_file(user_descriptors)
    end

    if descriptors isa AbstractString
        descriptors = _read_config_file(descriptors)
    end

    if generator_mapping isa AbstractString
        generator_mapping = get_generator_mapping(generator_mapping)
    end

    return PowerSystemTableData(
        base_power,
        category_to_df,
        timeseries_metadata_file,
        directory,
        user_descriptors,
        descriptors,
        generator_mapping,
    )
end

"""
Reads in all the data stored in csv files
The general format for data is
    folder:
        gen.csv
        branch.csv
        bus.csv
        ..
        load.csv

# Arguments
- `directory::AbstractString`: directory containing CSV files
- `base_power::Float64`: base power for System
- `user_descriptor_file::AbstractString`: customized input descriptor file
- `descriptor_file=POWER_SYSTEM_DESCRIPTOR_FILE`: PowerSystems descriptor file
- `generator_mapping_file=GENERATOR_MAPPING_FILE`: generator mapping configuration file
"""
function PowerSystemTableData(
    directory::AbstractString,
    base_power::Float64,
    user_descriptor_file::AbstractString;
    descriptor_file = POWER_SYSTEM_DESCRIPTOR_FILE,
    generator_mapping_file = GENERATOR_MAPPING_FILE,
    timeseries_metadata_file = joinpath(directory, "timeseries_pointers"),
)
    files = readdir(directory)
    REGEX_DEVICE_TYPE = r"(.*?)\.csv"
    REGEX_IS_FOLDER = r"^[A-Za-z]+$"
    data = Dict{String, Any}()

    if length(files) == 0
        error("No files in the folder")
    else
        data["base_power"] = base_power
    end

    encountered_files = 0
    for d_file in files
        try
            if match(REGEX_IS_FOLDER, d_file) !== nothing
                @info "Parsing csv files in $d_file ..."
                d_file_data = Dict{String, Any}()
                for file in readdir(joinpath(directory, d_file))
                    if match(REGEX_DEVICE_TYPE, file) !== nothing
                        @info "Parsing csv data in $file ..."
                        encountered_files += 1
                        fpath = joinpath(directory, d_file, file)
                        raw_data = DataFrames.DataFrame(CSV.File(fpath))
                        d_file_data[split(file, r"[.]")[1]] = raw_data
                    end
                end

                if length(d_file_data) > 0
                    data[d_file] = d_file_data
                    @info "Successfully parsed $d_file"
                end

            elseif match(REGEX_DEVICE_TYPE, d_file) !== nothing
                @info "Parsing csv data in $d_file ..."
                encountered_files += 1
                fpath = joinpath(directory, d_file)
                raw_data = DataFrames.DataFrame(CSV.File(fpath))
                data[split(d_file, r"[.]")[1]] = raw_data
                @info "Successfully parsed $d_file"
            end
        catch ex
            @error "Error occurred while parsing $d_file" exception = ex
            throw(ex)
        end
    end
    if encountered_files == 0
        error("No csv files or folders in $directory")
    end

    return PowerSystemTableData(
        data,
        directory,
        user_descriptor_file,
        descriptor_file,
        generator_mapping_file,
        timeseries_metadata_file = timeseries_metadata_file,
    )
end

"""
Return the custom name stored in the user descriptor file.

Throws DataFormatError if a required value is not found in the file.
"""
function get_user_field(
    data::PowerSystemTableData,
    category::InputCategory,
    field::AbstractString,
)
    if !haskey(data.user_descriptors, category)
        throw(DataFormatError("Invalid category=$category"))
    end

    try
        for item in data.user_descriptors[category]
            if item["name"] == field
                return item["custom_name"]
            end
        end
    catch
        (err)
        if err == KeyError
            msg = "Failed to find category=$category field=$field in input descriptors $err"
            throw(DataFormatError(msg))
        else
            throw(err)
        end
    end
end

"""Return a vector of user-defined fields for the category."""
function get_user_fields(data::PowerSystemTableData, category::InputCategory)
    if !haskey(data.user_descriptors, category)
        throw(DataFormatError("Invalid category=$category"))
    end

    return [x["name"] for x in data.user_descriptors[category]]
end

"""Return the dataframe for the category."""
function get_dataframe(data::PowerSystemTableData, category::InputCategory)
    df = get(data.category_to_df, category, DataFrames.DataFrame())
    isempty(df) && @warn("Missing $category data.")
    return df
end

"""
Return a NamedTuple of parameters from the descriptor file for each row of a dataframe,
making type conversions as necessary.

Refer to the PowerSystems descriptor file for field names that will be created.
"""
function iterate_rows(data::PowerSystemTableData, category; na_to_nothing = true)
    df = get_dataframe(data, category)
    field_infos = _get_field_infos(data, category, names(df))
    Channel() do channel
        for row in eachrow(df)
            obj = _read_data_row(data, row, field_infos; na_to_nothing = na_to_nothing)
            put!(channel, obj)
        end
    end
end

"""
Construct a System from PowerSystemTableData data.

# Arguments
- `time_series_resolution::Union{DateTime, Nothing}=nothing`: only store time_series that match
  this resolution.
- `time_series_in_memory::Bool=false`: Store time series data in memory instead of HDF5 file
- `time_series_directory=nothing`: Store time series data in directory instead of tmpfs
- `runchecks::Bool=true`: Validate struct fields.

Throws DataFormatError if time_series with multiple resolutions are detected.
- A time_series has a different resolution than others.
- A time_series has a different horizon than others.

"""
function System(
    data::PowerSystemTableData;
    time_series_resolution = nothing,
    time_series_in_memory = false,
    time_series_directory = nothing,
    runchecks = true,
    kwargs...,
)
    sys = System(
        data.base_power;
        time_series_in_memory = time_series_in_memory,
        time_series_directory = time_series_directory,
        runchecks = runchecks,
        kwargs...,
    )
    set_units_base_system!(sys, IS.UnitSystem.DEVICE_BASE)

    loadzone_csv_parser!(sys, data)
    bus_csv_parser!(sys, data)

    # Services and time_series must be last.
    parsers = (
        (get_dataframe(data, InputCategory.BRANCH), branch_csv_parser!),
        (get_dataframe(data, InputCategory.DC_BRANCH), dc_branch_csv_parser!),
        (get_dataframe(data, InputCategory.GENERATOR), gen_csv_parser!),
        (get_dataframe(data, InputCategory.LOAD), load_csv_parser!),
        (get_dataframe(data, InputCategory.RESERVE), services_csv_parser!),
    )

    for (val, parser) in parsers
        if !isnothing(val)
            parser(sys, data)
        end
    end

    timeseries_metadata_file =
        get(kwargs, :timeseries_metadata_file, getfield(data, :timeseries_metadata_file))

    if !isnothing(timeseries_metadata_file)
        add_time_series!(sys, timeseries_metadata_file; resolution = time_series_resolution)
    end

    check(sys)
    return sys
end

"""
Add buses and areas to the System from the raw data.

"""
function bus_csv_parser!(sys::System, data::PowerSystemTableData)
    for (ix, bus) in enumerate(iterate_rows(data, InputCategory.BUS))
        name = bus.name
        bus_type =
            isnothing(bus.bus_type) ? nothing : get_enum_value(BusTypes, bus.bus_type)
        voltage_limits = make_minmaxlimits(bus.voltage_limits_min, bus.voltage_limits_max)

        area_name = string(get(bus, :area, "area"))
        area = get_component(Area, sys, area_name)
        if isnothing(area)
            area = Area(area_name)
            add_component!(sys, area)
        end
        zone = get(bus, :zone, nothing)
        bus_id = isnothing(bus.bus_id) ? ix : bus.bus_id

        ps_bus = Bus(;
            number = bus_id,
            name = name,
            bustype = bus_type,
            angle = bus.angle,
            magnitude = bus.voltage,
            voltage_limits = voltage_limits,
            base_voltage = bus.base_voltage,
            area = area,
            load_zone = get_component(LoadZone, sys, string(zone)),
        )
        add_component!(sys, ps_bus)

        # add load if the following info is nonzero
        if (bus.max_active_power != 0.0) || (bus.max_reactive_power != 0.0)
            load = PowerLoad(
                name = name,
                available = true,
                bus = ps_bus,
                model = LoadModels.ConstantPower,
                active_power = bus.active_power,
                reactive_power = bus.reactive_power,
                base_power = bus.base_power,
                max_active_power = bus.max_active_power,
                max_reactive_power = bus.max_reactive_power,
            )
            add_component!(sys, load)
        end
    end
end

"""
Add branches to the System from the raw data.

"""
function branch_csv_parser!(sys::System, data::PowerSystemTableData)
    available = true

    for branch in iterate_rows(data, InputCategory.BRANCH)
        bus_from = get_bus(sys, branch.connection_points_from)
        bus_to = get_bus(sys, branch.connection_points_to)
        name = get(branch, :name, get_name(bus_from) * "_" * get_name(bus_to))
        connection_points = Arc(bus_from, bus_to)
        pf = branch.active_power_flow
        qf = branch.reactive_power_flow

        #TODO: noop math...Phase-Shifting Transformer angle
        alpha = (branch.primary_shunt / 2) - (branch.primary_shunt / 2)
        branch_type =
            get_branch_type(branch.tap, alpha, get(branch, :is_transformer, nothing))
        if branch_type == Line
            b = branch.primary_shunt / 2
            value = Line(
                name = name,
                available = available,
                active_power_flow = pf,
                reactive_power_flow = qf,
                arc = connection_points,
                r = branch.r,
                x = branch.x,
                b = (from = b, to = b),
                rate = branch.rate,
                angle_limits = (
                    min = branch.min_angle_limits,
                    max = branch.max_angle_limits,
                ),
            )
        elseif branch_type == Transformer2W
            value = Transformer2W(
                name = name,
                available = available,
                active_power_flow = pf,
                reactive_power_flow = qf,
                arc = connection_points,
                r = branch.r,
                x = branch.x,
                primary_shunt = branch.primary_shunt,
                rate = branch.rate,
            )
        elseif branch_type == TapTransformer
            value = TapTransformer(
                name = name,
                available = available,
                active_power_flow = pf,
                reactive_power_flow = qf,
                arc = connection_points,
                r = branch.r,
                x = branch.x,
                primary_shunt = branch.primary_shunt,
                tap = branch.tap,
                rate = branch.rate,
            )
        elseif branch_type == PhaseShiftingTransformer
            # TODO create PhaseShiftingTransformer
            error("Unsupported branch type $branch_type")
        else
            error("Unsupported branch type $branch_type")
        end

        add_component!(sys, value)
    end
end

"""
Add DC branches to the System from raw data.
"""
function dc_branch_csv_parser!(sys::System, data::PowerSystemTableData)
    function make_dc_limits(dc_branch, min, max)
        min_lim = dc_branch[min]
        if isnothing(dc_branch[min]) && isnothing(dc_branch[max])
            throw(DataFormatError("valid limits required for $min , $max"))
        elseif isnothing(dc_branch[min])
            min_lim = dc_branch[max] * -1.0
        end
        return (min = min_lim, max = dc_branch[max])
    end

    for dc_branch in iterate_rows(data, InputCategory.DC_BRANCH)
        available = true
        bus_from = get_bus(sys, dc_branch.connection_points_from)
        bus_to = get_bus(sys, dc_branch.connection_points_to)
        connection_points = Arc(bus_from, bus_to)

        if dc_branch.control_mode == "Power"
            mw_load = dc_branch.mw_load

            activepowerlimits_from = make_dc_limits(
                dc_branch,
                :min_active_power_limit_from,
                :max_active_power_limit_from,
            )
            activepowerlimits_to = make_dc_limits(
                dc_branch,
                :min_active_power_limit_to,
                :max_active_power_limit_to,
            )
            reactivepowerlimits_from = make_dc_limits(
                dc_branch,
                :min_reactive_power_limit_from,
                :max_reactive_power_limit_from,
            )
            reactivepowerlimits_to = make_dc_limits(
                dc_branch,
                :min_reactive_power_limit_to,
                :max_reactive_power_limit_to,
            )

            loss = (l0 = 0.0, l1 = dc_branch.loss) #TODO: Can we infer this from the other data?,

            value = HVDCLine(
                name = dc_branch.name,
                available = available,
                active_power_flow = dc_branch.active_power_flow,
                arc = connection_points,
                active_power_limits_from = activepowerlimits_from,
                active_power_limits_to = activepowerlimits_to,
                reactive_power_limits_from = reactivepowerlimits_from,
                reactive_power_limits_to = reactivepowerlimits_to,
                loss = loss,
            )
        else
            rectifier_taplimits = (
                min = dc_branch.rectifier_tap_limits_min,
                max = dc_branch.rectifier_tap_limits_max,
            )
            rectifier_xrc = dc_branch.rectifier_xrc #TODO: What is this?,
            rectifier_firingangle = dc_branch.rectifier_firingangle
            inverter_taplimits = (
                min = dc_branch.inverter_tap_limits_min,
                max = dc_branch.inverter_tap_limits_max,
            )
            inverter_xrc = dc_branch.inverter_xrc #TODO: What is this?
            inverter_firingangle = (
                min = dc_branch.inverter_firing_angle_min,
                max = dc_branch.inverter_firing_angle_max,
            )
            value = VSCDCLine(
                name = dc_branch.name,
                available = true,
                active_power_flow = pf,
                arc = connection_points,
                rectifier_taplimits = rectifier_taplimits,
                rectifier_xrc = rectifier_xrc,
                rectifier_firingangle = rectifier_firingangle,
                inverter_taplimits = inverter_taplimits,
                inverter_xrc = inverter_xrc,
                inverter_firingangle = inverter_firingangle,
            )
        end

        add_component!(sys, value)
    end
end

"""
Add generators to the System from the raw data.

"""
struct _HeatRateColumns
    columns::Base.Iterators.Zip{Tuple{Array{Symbol, 1}, Array{Symbol, 1}}}
end
struct _CostPointColumns
    columns::Base.Iterators.Zip{Tuple{Array{Symbol, 1}, Array{Symbol, 1}}}
end

function gen_csv_parser!(sys::System, data::PowerSystemTableData)
    output_point_fields = Vector{Symbol}()
    heat_rate_fields = Vector{Symbol}()
    cost_point_fields = Vector{Symbol}()
    fields = get_user_fields(data, InputCategory.GENERATOR)
    for field in fields
        if occursin("output_point", field)
            push!(output_point_fields, Symbol(field))
        elseif occursin("heat_rate_", field)
            push!(heat_rate_fields, Symbol(field))
        elseif occursin("cost_point_", field)
            push!(cost_point_fields, Symbol(field))
        end
    end

    @assert length(output_point_fields) > 0
    if length(heat_rate_fields) > 0 && length(cost_point_fields) > 0
        throw(IS.ConflictingInputsError("Heat rate and cost points are both defined"))
    elseif length(heat_rate_fields) > 0
        cost_colnames = _HeatRateColumns(zip(heat_rate_fields, output_point_fields))
    elseif length(cost_point_fields) > 0
        cost_colnames = _CostPointColumns(zip(cost_point_fields, output_point_fields))
    end

    for gen in iterate_rows(data, InputCategory.GENERATOR)
        @debug "making generator:" _group = IS.LOG_GROUP_PARSING gen.name
        bus = get_bus(sys, gen.bus_id)
        if isnothing(bus)
            throw(DataFormatError("could not find $(gen.bus_id)"))
        end

        generator = make_generator(data, gen, cost_colnames, bus)
        @debug "adding gen:" _group = IS.LOG_GROUP_PARSING generator
        if !isnothing(generator)
            add_component!(sys, generator)
        end
    end
end

"""
    load_csv_parser!(sys::System, data::PowerSystemTableData)

Add loads to the System from the raw load data.

"""
function load_csv_parser!(sys::System, data::PowerSystemTableData)
    for rawload in iterate_rows(data, InputCategory.LOAD)
        bus = get_bus(sys, rawload.bus_id)
        if isnothing(bus)
            throw(
                DataFormatError(
                    "could not find bus_number=$(rawload.bus_id) for load=$(rawload.name)",
                ),
            )
        end

        load = PowerLoad(
            name = rawload.name,
            available = rawload.available,
            bus = bus,
            model = LoadModels.ConstantPower,
            active_power = rawload.active_power,
            reactive_power = rawload.reactive_power,
            max_active_power = rawload.max_active_power,
            max_reactive_power = rawload.max_reactive_power,
            base_power = rawload.base_power,
        )
        add_component!(sys, load)
    end
end

"""
    loadzone_csv_parser!(sys::System, data::PowerSystemTableData)

Add branches to the System from the raw data.

"""
function loadzone_csv_parser!(sys::System, data::PowerSystemTableData)
    buses = get_dataframe(data, InputCategory.BUS)
    zone_column = get_user_field(data, InputCategory.BUS, "zone")
    if !in(zone_column, names(buses))
        @warn "Missing Data : no 'zone' information for buses, cannot create loads based on zones"
        return
    end

    zones = unique(buses[!, zone_column])
    for zone in zones
        bus_numbers = Set{Int}()
        active_powers = Vector{Float64}()
        reactive_powers = Vector{Float64}()
        for (ix, bus) in enumerate(iterate_rows(data, InputCategory.BUS))
            bus_number = isnothing(bus.bus_id) ? ix : bus.bus_id
            if bus.zone == zone
                push!(bus_numbers, bus_number)

                active_power = bus.max_active_power
                push!(active_powers, active_power)

                reactive_power = bus.max_reactive_power
                push!(reactive_powers, reactive_power)
            end
        end

        name = string(zone)
        load_zone = LoadZone(name, sum(active_powers), sum(reactive_powers))
        add_component!(sys, load_zone)
    end
end

"""
Add services to the System from the raw data.
"""
function services_csv_parser!(sys::System, data::PowerSystemTableData)
    bus_id_column = get_user_field(data, InputCategory.BUS, "bus_id")
    bus_area_column = get_user_field(data, InputCategory.BUS, "area")

    # Shortcut for data that looks like "(val1,val2,val3)"
    make_array(x) = isnothing(x) ? x : split(strip(x, ['(', ')']), ",")

    function _add_device!(contributing_devices, device_categories, name)
        component = []
        for dev_category in device_categories
            component_type = _get_component_type_from_category(dev_category)
            components = get_components_by_name(component_type, sys, name)
            if length(components) == 0
                # There multiple categories, so we might not find a match in some.
                continue
            elseif length(components) == 1
                push!(component, components[1])
            else
                msg = "Found duplicate names type=$component_type name=$name"
                throw(DataFormatError(msg))
            end
        end
        if length(component) > 1
            msg = "Found duplicate components with name=$name"
            throw(DataFormatError(msg))
        elseif length(component) == 1
            push!(contributing_devices, component[1])
        end
    end

    for reserve in iterate_rows(data, InputCategory.RESERVE)
        device_categories = make_array(reserve.eligible_device_categories)
        device_subcategories =
            make_array(get(reserve, :eligible_device_subcategories, nothing))
        devices = make_array(get(reserve, :contributing_devices, nothing))
        regions = make_array(reserve.eligible_regions) #TODO: rename to "area"
        requirement = get(reserve, :requirement, nothing)
        contributing_devices = Vector{Device}()

        if isnothing(device_subcategories)
            @info("Adding contributing components for $(reserve.name) by component name")
            for device in devices
                _add_device!(contributing_devices, device_categories, device)
            end
        else
            @info("Adding contributing generators for $(reserve.name) by category")
            for gen in iterate_rows(data, InputCategory.GENERATOR)
                buses = get_dataframe(data, InputCategory.BUS)
                bus_ids = buses[!, bus_id_column]
                gen_type =
                    get_generator_type(gen.fuel, gen.unit_type, data.generator_mapping)
                sys_gen = get_component(
                    get_generator_type(gen.fuel, gen.unit_type, data.generator_mapping),
                    sys,
                    gen.name,
                )
                area = string(
                    buses[bus_ids .== get_number(get_bus(sys_gen)), bus_area_column][1],
                )
                if gen.category in device_subcategories && area in regions
                    _add_device!(contributing_devices, device_categories, gen.name)
                end
            end

            unused_categories = setdiff(
                device_subcategories,
                get_dataframe(data, InputCategory.GENERATOR)[
                    !,
                    get_user_field(data, InputCategory.GENERATOR, "category"),
                ],
            )
            for cat in unused_categories
                @warn(
                    "Device category: $cat not found in generators data; adding contributing devices by category only supported for generator data"
                )
            end
        end

        if length(contributing_devices) == 0
            throw(
                DataFormatError(
                    "did not find contributing devices for service $(reserve.name)",
                ),
            )
        end

        direction = get_reserve_direction(reserve.direction)
        if isnothing(requirement)
            service = StaticReserve{direction}(reserve.name, true, reserve.timeframe, 0.0)
        else
            service = VariableReserve{direction}(
                reserve.name,
                true,
                reserve.timeframe,
                requirement,
            )
        end

        add_service!(sys, service, contributing_devices)
    end
end

function get_reserve_direction(direction::AbstractString)
    if direction == "Up"
        return ReserveUp
    elseif direction == "Down"
        return ReserveDown
    else
        throw(DataFormatError("invalid reserve direction $direction"))
    end
end

"""Creates a generator of any type."""
function make_generator(data::PowerSystemTableData, gen, cost_colnames, bus)
    generator = nothing
    gen_type =
        get_generator_type(gen.fuel, get(gen, :unit_type, nothing), data.generator_mapping)

    if isnothing(gen_type)
        @error "Cannot recognize generator type" gen.name
    elseif gen_type == ThermalStandard
        generator = make_thermal_generator(data, gen, cost_colnames, bus)
    elseif gen_type == ThermalMultiStart
        generator = make_thermal_generator_multistart(data, gen, cost_colnames, bus)
    elseif gen_type <: HydroGen
        generator = make_hydro_generator(gen_type, data, gen, cost_colnames, bus)
    elseif gen_type <: RenewableGen
        generator = make_renewable_generator(gen_type, data, gen, cost_colnames, bus)
    elseif gen_type == GenericBattery
        storage = get_storage_by_generator(data, gen.name).head
        generator = make_storage(data, gen, storage, bus)
    else
        @error "Skipping unsupported generator" gen.name gen_type
    end

    return generator
end

function calculate_variable_cost(
    data::PowerSystemTableData,
    gen,
    cost_colnames::_HeatRateColumns,
    base_power,
)
    fuel_cost = gen.fuel_price / 1000.0

    vom = isnothing(gen.variable_cost) ? 0.0 : gen.variable_cost

    if fuel_cost > 0.0
        var_cost =
            [(getfield(gen, hr), getfield(gen, mw)) for (hr, mw) in cost_colnames.columns]
        var_cost = unique([
            (tryparse(Float64, string(c[1])), tryparse(Float64, string(c[2]))) for
            c in var_cost if !in(nothing, c)
        ])
        if isempty(var_cost)
            @warn "Unable to calculate variable cost for $(gen.name)" var_cost maxlog = 5
        end
    else
        var_cost = [(0.0, 0.0)]
    end

    if length(var_cost) > 1
        var_cost[2:end] = [
            (
                (
                    var_cost[i][1] * fuel_cost * (var_cost[i][2] - var_cost[i - 1][2]) +
                    var_cost[i][2] * vom
                ),
                var_cost[i][2],
            ) .* gen.active_power_limits_max .* base_power for i in 2:length(var_cost)
        ]
        var_cost[1] =
            ((var_cost[1][1] * fuel_cost + vom) * var_cost[1][2], var_cost[1][2]) .*
            gen.active_power_limits_max .* base_power

        fixed = max(
            0.0,
            var_cost[1][1] -
            (var_cost[2][1] / (var_cost[2][2] - var_cost[1][2]) * var_cost[1][2]),
        )
        var_cost[1] = (var_cost[1][1] - fixed, var_cost[1][2])

        for i in 2:length(var_cost)
            var_cost[i] = (var_cost[i - 1][1] + var_cost[i][1], var_cost[i][2])
        end

    elseif length(var_cost) == 1
        # if there is only one point, use it to determine the constant $/MW cost
        var_cost = var_cost[1][1] * fuel_cost + vom
        fixed = 0.0
    end
    return var_cost, fixed, fuel_cost
end

function calculate_variable_cost(
    data::PowerSystemTableData,
    gen,
    cost_colnames::_CostPointColumns,
    base_power,
)
    vom = isnothing(gen.variable_cost) ? 0.0 : gen.variable_cost

    var_cost = [(getfield(gen, c), getfield(gen, mw)) for (c, mw) in cost_colnames.columns]
    var_cost = unique([
        (tryparse(Float64, string(c[1])), tryparse(Float64, string(c[2]))) for
        c in var_cost if !in(nothing, c)
    ])

    var_cost = [
        ((var_cost[i][1] + vom) * var_cost[i][2], var_cost[i][2]) .*
        gen.active_power_limits_max .* base_power for i in 1:length(var_cost)
    ]

    if length(var_cost) > 1
        fixed = max(
            0.0,
            var_cost[1][1] -
            (var_cost[2][1] / (var_cost[2][2] - var_cost[1][2]) * var_cost[1][2]),
        )
        var_cost = [(var_cost[i][1] - fixed, var_cost[i][2]) for i in 1:length(var_cost)]
    elseif length(var_cost) == 1
        var_cost = var_cost[1][1] + vom
        fixed = 0.0
    end

    return var_cost, fixed, 0.0
end

function calculate_uc_cost(data, gen, fuel_cost)
    startup_cost = gen.startup_cost
    if isnothing(startup_cost)
        if !isnothing(gen.startup_heat_cold_cost)
            startup_cost = gen.startup_heat_cold_cost * fuel_cost * 1000
        else
            startup_cost = 0.0
            @warn "No startup_cost defined for $(gen.name), setting to $startup_cost" maxlog =
                5
        end
    end

    shutdown_cost = get(gen, :shutdown_cost, nothing)
    if isnothing(shutdown_cost)
        @warn "No shutdown_cost defined for $(gen.name), setting to 0.0" maxlog = 1
        shutdown_cost = 0.0
    end

    return startup_cost, shutdown_cost
end

function make_minmaxlimits(min::Union{Nothing, Float64}, max::Union{Nothing, Float64})
    if isnothing(min) && isnothing(max)
        minmax = nothing
    else
        minmax = (min = min, max = max)
    end
    return minmax
end

function make_ramplimits(
    gen;
    ramplimcol = :ramp_limits,
    rampupcol = :ramp_up,
    rampdncol = :ramp_down,
)
    ramp = get(gen, ramplimcol, nothing)
    if !isnothing(ramp)
        up = ramp
        down = ramp
    else
        up = get(gen, rampupcol, ramp)
        up = typeof(up) <: AbstractString ? tryparse(Float64, up) : up
        down = get(gen, rampdncol, ramp)
        down = typeof(down) <: AbstractString ? tryparse(Float64, down) : down
    end
    ramplimits = isnothing(up) && isnothing(down) ? nothing : (up = up, down = down)
    return ramplimits
end

function make_timelimits(gen, up_column::Symbol, down_column::Symbol)
    up_time = get(gen, up_column, nothing)
    up_time = typeof(up_time) <: AbstractString ? tryparse(Float64, up_time) : up_time

    down_time = get(gen, down_column, nothing)
    down_time =
        typeof(down_time) <: AbstractString ? tryparse(Float64, down_time) : down_time

    timelimits =
        isnothing(up_time) && isnothing(down_time) ? nothing :
        (up = up_time, down = down_time)
    return timelimits
end

function make_reactive_params(
    gen;
    powerfield = :reactive_power,
    minfield = :reactive_power_limits_min,
    maxfield = :reactive_power_limits_max,
)
    reactive_power = get(gen, powerfield, 0.0)
    reactive_power_limits_min = get(gen, minfield, nothing)
    reactive_power_limits_max = get(gen, maxfield, nothing)
    if isnothing(reactive_power_limits_min) && isnothing(reactive_power_limits_max)
        reactive_power_limits = nothing
    elseif isnothing(reactive_power_limits_min)
        reactive_power_limits = (min = 0.0, max = reactive_power_limits_max)
    else
        reactive_power_limits =
            (min = reactive_power_limits_min, max = reactive_power_limits_max)
    end
    return reactive_power, reactive_power_limits
end

function make_thermal_generator(data::PowerSystemTableData, gen, cost_colnames, bus)
    @debug "Making ThermaStandard" _group = IS.LOG_GROUP_PARSING gen.name
    active_power_limits =
        (min = gen.active_power_limits_min, max = gen.active_power_limits_max)
    (reactive_power, reactive_power_limits) = make_reactive_params(gen)
    rating = calculate_rating(active_power_limits, reactive_power_limits)
    ramplimits = make_ramplimits(gen)
    timelimits = make_timelimits(gen, :min_up_time, :min_down_time)
    primemover = parse_enum_mapping(PrimeMovers, gen.unit_type)
    fuel = parse_enum_mapping(ThermalFuels, gen.fuel)

    base_power = gen.base_mva
    var_cost, fixed, fuel_cost =
        calculate_variable_cost(data, gen, cost_colnames, base_power)
    startup_cost, shutdown_cost = calculate_uc_cost(data, gen, fuel_cost)
    op_cost = ThreePartCost(var_cost, fixed, startup_cost, shutdown_cost)

    return ThermalStandard(
        name = gen.name,
        available = gen.available,
        status = gen.status_at_start,
        bus = bus,
        active_power = gen.active_power,
        reactive_power = reactive_power,
        rating = rating,
        prime_mover = primemover,
        fuel = fuel,
        active_power_limits = active_power_limits,
        reactive_power_limits = reactive_power_limits,
        ramp_limits = ramplimits,
        time_limits = timelimits,
        operation_cost = op_cost,
        base_power = base_power,
    )
end

function make_thermal_generator_multistart(
    data::PowerSystemTableData,
    gen,
    cost_colnames,
    bus,
)
    thermal_gen = make_thermal_generator(data, gen, cost_colnames, bus)

    @debug "Making ThermalMultiStart" _group = IS.LOG_GROUP_PARSING gen.name
    base_power = get_base_power(thermal_gen)
    var_cost, fixed, fuel_cost =
        calculate_variable_cost(data, gen, cost_colnames, base_power)
    if var_cost isa Float64
        no_load_cost = 0.0
        var_cost = VariableCost(var_cost)
    else
        no_load_cost = var_cost[1][1]
        var_cost =
            VariableCost([(c - no_load_cost, pp - var_cost[1][2]) for (c, pp) in var_cost])
    end
    lag_hot =
        isnothing(gen.hot_start_time) ? get_time_limits(thermal_gen).down :
        gen.hot_start_time
    lag_warm = isnothing(gen.warm_start_time) ? 0.0 : gen.warm_start_time
    lag_cold = isnothing(gen.cold_start_time) ? 0.0 : gen.cold_start_time
    startup_timelimits = (hot = lag_hot, warm = lag_warm, cold = lag_cold)
    start_types = sum(values(startup_timelimits) .> 0.0)
    startup_ramp = isnothing(gen.startup_ramp) ? 0.0 : gen.startup_ramp
    shutdown_ramp = isnothing(gen.shutdown_ramp) ? 0.0 : gen.shutdown_ramp
    power_trajectory = (startup = startup_ramp, shutdown = shutdown_ramp)
    hot_start_cost = isnothing(gen.hot_start_cost) ? gen.startup_cost : gen.hot_start_cost
    if isnothing(hot_start_cost)
        if hasfield(typeof(gen), :startup_heat_cold_cost)
            hot_start_cost = gen.startup_heat_cold_cost * fuel_cost * 1000
        else
            hot_start_cost = 0.0
            @warn "No hot_start_cost or startup_cost defined for $(gen.name), setting to $startup_cost" maxlog =
                5
        end
    end
    warm_start_cost = isnothing(gen.warm_start_cost) ? START_COST : gen.hot_start_cost #TODO
    cold_start_cost = isnothing(gen.cold_start_cost) ? START_COST : gen.cold_start_cost
    startup_cost = (hot = hot_start_cost, warm = warm_start_cost, cold = cold_start_cost)

    shutdown_cost = gen.shutdown_cost
    if isnothing(shutdown_cost)
        @warn "No shutdown_cost defined for $(gen.name), setting to 0.0" maxlog = 1
        shutdown_cost = 0.0
    end

    op_cost = MultiStartCost(var_cost, no_load_cost, fixed, startup_cost, shutdown_cost)

    return ThermalMultiStart(;
        name = get_name(thermal_gen),
        available = get_available(thermal_gen),
        status = get_status(thermal_gen),
        bus = get_bus(thermal_gen),
        active_power = get_active_power(thermal_gen),
        reactive_power = get_reactive_power(thermal_gen),
        rating = get_rating(thermal_gen),
        prime_mover = get_prime_mover(thermal_gen),
        fuel = get_fuel(thermal_gen),
        active_power_limits = get_active_power_limits(thermal_gen),
        reactive_power_limits = get_reactive_power_limits(thermal_gen),
        ramp_limits = get_ramp_limits(thermal_gen),
        power_trajectory = power_trajectory,
        time_limits = get_time_limits(thermal_gen),
        start_time_limits = startup_timelimits,
        start_types = start_types,
        operation_cost = op_cost,
        base_power = get_base_power(thermal_gen),
        time_at_status = get_time_at_status(thermal_gen),
        must_run = gen.must_run,
    )
end

function make_hydro_generator(gen_type, data::PowerSystemTableData, gen, cost_colnames, bus)
    @debug "Making HydroGen" _group = IS.LOG_GROUP_PARSING gen.name
    active_power_limits =
        (min = gen.active_power_limits_min, max = gen.active_power_limits_max)
    (reactive_power, reactive_power_limits) = make_reactive_params(gen)
    rating = calculate_rating(active_power_limits, reactive_power_limits)
    ramp_limits = make_ramplimits(gen)
    min_up_time = gen.min_up_time
    min_down_time = gen.min_down_time
    time_limits = make_timelimits(gen, :min_up_time, :min_down_time)
    base_power = gen.base_mva

    if gen_type == HydroEnergyReservoir || gen_type == HydroPumpedStorage
        if !haskey(data.category_to_df, InputCategory.STORAGE)
            throw(DataFormatError("Storage information must defined in storage.csv"))
        end

        storage = get_storage_by_generator(data, gen.name)

        var_cost, fixed, fuel_cost =
            calculate_variable_cost(data, gen, cost_colnames, base_power)
        operation_cost = TwoPartCost(var_cost, fixed)

        if gen_type == HydroEnergyReservoir
            @debug "Creating $(gen.name) as HydroEnergyReservoir" _group =
                IS.LOG_GROUP_PARSING

            hydro_gen = HydroEnergyReservoir(
                name = gen.name,
                available = gen.available,
                bus = bus,
                active_power = gen.active_power,
                reactive_power = reactive_power,
                prime_mover = parse_enum_mapping(PrimeMovers, gen.unit_type),
                rating = rating,
                active_power_limits = active_power_limits,
                reactive_power_limits = reactive_power_limits,
                ramp_limits = ramp_limits,
                time_limits = time_limits,
                operation_cost = operation_cost,
                base_power = base_power,
                storage_capacity = storage.head.storage_capacity,
                inflow = storage.head.input_active_power_limit_max,
                initial_storage = storage.head.energy_level,
            )

        elseif gen_type == HydroPumpedStorage
            @debug "Creating $(gen.name) as HydroPumpedStorage" _group =
                IS.LOG_GROUP_PARSING

            pump_active_power_limits = (
                min = gen.pump_active_power_limits_min,
                max = gen.pump_active_power_limits_max,
            )
            (pump_reactive_power, pump_reactive_power_limits) = make_reactive_params(
                gen,
                powerfield = :pump_reactive_power,
                minfield = :pump_reactive_power_limits_min,
                maxfield = :pump_reactive_power_limits_max,
            )
            pump_rating =
                calculate_rating(pump_active_power_limits, pump_reactive_power_limits)
            pump_ramp_limits = make_ramplimits(
                gen;
                ramplimcol = :pump_ramp_limits,
                rampupcol = :pump_ramp_up,
                rampdncol = :pump_ramp_down,
            )
            pump_time_limits = make_timelimits(gen, :pump_min_up_time, :pump_min_down_time)
            hydro_gen = HydroPumpedStorage(
                name = gen.name,
                available = gen.available,
                bus = bus,
                active_power = gen.active_power,
                reactive_power = reactive_power,
                rating = rating,
                base_power = base_power,
                prime_mover = parse_enum_mapping(PrimeMovers, gen.unit_type),
                active_power_limits = active_power_limits,
                reactive_power_limits = reactive_power_limits,
                ramp_limits = ramp_limits,
                time_limits = time_limits,
                rating_pump = pump_rating,
                active_power_limits_pump = pump_active_power_limits,
                reactive_power_limits_pump = pump_reactive_power_limits,
                ramp_limits_pump = pump_ramp_limits,
                time_limits_pump = pump_time_limits,
                storage_capacity = (
                    up = storage.head.storage_capacity,
                    down = storage.head.storage_capacity,
                ),
                inflow = storage.head.input_active_power_limit_max,
                outflow = storage.tail.input_active_power_limit_max,
                initial_storage = (
                    up = storage.head.energy_level,
                    down = storage.tail.energy_level,
                ),
                storage_target = (
                    up = storage.head.storage_target,
                    down = storage.tail.storage_target,
                ),
                operation_cost = operation_cost,
                pump_efficiency = storage.tail.efficiency,
            )
        end
    elseif gen_type == HydroDispatch
        @debug "Creating $(gen.name) as HydroDispatch" _group = IS.LOG_GROUP_PARSING
        hydro_gen = HydroDispatch(
            name = gen.name,
            available = gen.available,
            bus = bus,
            active_power = gen.active_power,
            reactive_power = reactive_power,
            rating = rating,
            prime_mover = parse_enum_mapping(PrimeMovers, gen.unit_type),
            active_power_limits = active_power_limits,
            reactive_power_limits = reactive_power_limits,
            ramp_limits = ramp_limits,
            time_limits = time_limits,
            base_power = base_power,
        )
    else
        error("Tabular data parser does not currently support $gen_type creation")
    end
    return hydro_gen
end

function get_storage_by_generator(data::PowerSystemTableData, gen_name::AbstractString)
    head = []
    tail = []
    for s in iterate_rows(data, InputCategory.STORAGE)
        if s.generator_name == gen_name
            if occursin("head", normalize(s.position, casefold = true))
                push!(head, s)
            elseif occursin("tail", normalize(s.position, casefold = true))
                push!(tail, s)
            end
        end
    end

    if length(head) != 1
        throw(
            DataFormatError(
                "Exactly 1 head storage is required but $gen_name has $(length(head)) head storages defined",
            ),
        )
    elseif length(tail) > 1
        throw(
            DataFormatError(
                "$gen_name storage generator cannot have more than 1 tail storage defined",
            ),
        )
    end
    tail = length(tail) > 0 ? tail[1] : nothing

    return (head = head[1], tail = tail)
end

function make_renewable_generator(
    gen_type,
    data::PowerSystemTableData,
    gen,
    cost_colnames,
    bus,
)
    @debug "Making RenewableGen" _group = IS.LOG_GROUP_PARSING gen.name
    generator = nothing
    active_power_limits =
        (min = gen.active_power_limits_min, max = gen.active_power_limits_max)
    (reactive_power, reactive_power_limits) = make_reactive_params(gen)
    rating = calculate_rating(active_power_limits, reactive_power_limits)
    base_power = gen.base_mva
    var_cost, fixed, fuel_cost =
        calculate_variable_cost(data, gen, cost_colnames, base_power)
    operation_cost = TwoPartCost(var_cost, fixed)

    if gen_type == RenewableDispatch
        @debug "Creating $(gen.name) as RenewableDispatch" _group = IS.LOG_GROUP_PARSING
        generator = RenewableDispatch(
            name = gen.name,
            available = gen.available,
            bus = bus,
            active_power = gen.active_power,
            reactive_power = reactive_power,
            rating = rating,
            prime_mover = parse_enum_mapping(PrimeMovers, gen.unit_type),
            reactive_power_limits = reactive_power_limits,
            power_factor = gen.power_factor,
            operation_cost = operation_cost,
            base_power = base_power,
        )
    elseif gen_type == RenewableFix
        @debug "Creating $(gen.name) as RenewableFix" _group = IS.LOG_GROUP_PARSING
        generator = RenewableFix(
            name = gen.name,
            available = gen.available,
            bus = bus,
            active_power = gen.active_power,
            reactive_power = reactive_power,
            rating = rating,
            prime_mover = parse_enum_mapping(PrimeMovers, gen.unit_type),
            power_factor = gen.power_factor,
            base_power = base_power,
        )
    else
        error("Unsupported type $gen_type")
    end

    return generator
end

function make_storage(data::PowerSystemTableData, gen, storage, bus)
    @debug "Making Storge" _group = IS.LOG_GROUP_PARSING storage.name
    state_of_charge_limits =
        (min = storage.min_storage_capacity, max = storage.storage_capacity)
    input_active_power_limits = (
        min = storage.input_active_power_limit_min,
        max = storage.input_active_power_limit_max,
    )
    output_active_power_limits = (
        min = storage.output_active_power_limit_min,
        max = isnothing(storage.output_active_power_limit_max) ?
              gen.active_power_limits_max : storage.output_active_power_limit_max,
    )
    efficiency = (in = storage.input_efficiency, out = storage.output_efficiency)
    (reactive_power, reactive_power_limits) = make_reactive_params(storage)
    battery = GenericBattery(;
        name = gen.name,
        available = storage.available,
        bus = bus,
        prime_mover = parse_enum_mapping(PrimeMovers, gen.unit_type),
        initial_energy = storage.energy_level,
        state_of_charge_limits = state_of_charge_limits,
        rating = storage.rating,
        active_power = storage.active_power,
        input_active_power_limits = input_active_power_limits,
        output_active_power_limits = output_active_power_limits,
        efficiency = efficiency,
        reactive_power = reactive_power,
        reactive_power_limits = reactive_power_limits,
        base_power = storage.base_power,
    )

    return battery
end

const CATEGORY_STR_TO_COMPONENT = Dict{String, DataType}(
    "Bus" => Bus,
    "Generator" => Generator,
    "Reserve" => Service,
    "LoadZone" => LoadZone,
    "ElectricLoad" => ElectricLoad,
)

function _get_component_type_from_category(category::AbstractString)
    component_type = get(CATEGORY_STR_TO_COMPONENT, category, nothing)
    if isnothing(component_type)
        throw(DataFormatError("unsupported category=$category"))
    end

    return component_type
end

function _read_config_file(file_path::String)
    return open(file_path) do io
        data = YAML.load(io)
        # Replace keys with enums.
        config_data = Dict{InputCategory, Vector}()
        for (key, val) in data
            # TODO: need to change user_descriptors.yaml to use reserve instead.
            if key == "reserves"
                key = "reserve"
            end
            config_data[get_enum_value(InputCategory, key)] = val
        end
        return config_data
    end
end

"""Stores user-customized information for required dataframe columns."""
struct _FieldInfo
    name::String
    custom_name::String
    per_unit_conversion::NamedTuple{
        (:From, :To, :Reference),
        Tuple{UnitSystem, UnitSystem, String},
    }
    unit_conversion::Union{NamedTuple{(:From, :To), Tuple{String, String}}, Nothing}
    default_value::Any
    # TODO unit, value ranges and options
end

function _get_field_infos(data::PowerSystemTableData, category::InputCategory, df_names)
    if !haskey(data.user_descriptors, category)
        throw(DataFormatError("Invalid category=$category"))
    end

    if !haskey(data.descriptors, category)
        throw(DataFormatError("Invalid category=$category"))
    end

    # Cache whether PowerSystems uses a column's values as system-per-unit.
    # The user's descriptors indicate that the raw data is already system-per-unit or not.
    per_unit = Dict{String, IS.UnitSystem}()
    unit = Dict{String, Union{String, Nothing}}()
    custom_names = Dict{String, String}()
    for descriptor in data.user_descriptors[category]
        custom_name = descriptor["custom_name"]
        if descriptor["custom_name"] in df_names
            per_unit[descriptor["name"]] = get_enum_value(
                IS.UnitSystem,
                get(descriptor, "unit_system", "NATURAL_UNITS"),
            )
            unit[descriptor["name"]] = get(descriptor, "unit", nothing)
            custom_names[descriptor["name"]] = custom_name
        else
            @warn "User-defined column name $custom_name is not in dataframe."
        end
    end

    fields = Vector{_FieldInfo}()

    for item in data.descriptors[category]
        name = item["name"]
        item_unit_system =
            get_enum_value(IS.UnitSystem, get(item, "unit_system", "NATURAL_UNITS"))
        per_unit_reference = get(item, "base_reference", "base_power")
        default_value = get(item, "default_value", "required")
        if default_value == "system_base_power"
            default_value = data.base_power
        end

        if name in keys(custom_names)
            custom_name = custom_names[name]

            if item_unit_system == IS.UnitSystem.NATURAL_UNITS &&
               per_unit[name] != IS.UnitSystem.NATURAL_UNITS
                throw(DataFormatError("$name cannot be defined as $(per_unit[name])"))
            end

            pu_conversion = (
                From = per_unit[name],
                To = item_unit_system,
                Reference = per_unit_reference,
            )

            expected_unit = get(item, "unit", nothing)
            if !isnothing(expected_unit) &&
               !isnothing(unit[name]) &&
               expected_unit != unit[name]
                unit_conversion = (From = unit[name], To = expected_unit)
            else
                unit_conversion = nothing
            end
        else
            custom_name = name
            pu_conversion = (
                From = item_unit_system,
                To = item_unit_system,
                Reference = per_unit_reference,
            )
            unit_conversion = nothing
        end

        push!(
            fields,
            _FieldInfo(name, custom_name, pu_conversion, unit_conversion, default_value),
        )
    end

    return fields
end

"""Reads values from dataframe row and performs necessary conversions."""
function _read_data_row(data::PowerSystemTableData, row, field_infos; na_to_nothing = true)
    fields = Vector{String}()
    vals = Vector()
    for field_info in field_infos
        if field_info.custom_name in names(row)
            value = row[field_info.custom_name]
        else
            value = field_info.default_value
            value == "required" && throw(DataFormatError("$(field_info.name) is required"))
            @debug "Column $(field_info.custom_name) doesn't exist in df, enabling use of default value of $(field_info.default_value)" _group =
                IS.LOG_GROUP_PARSING maxlog = 1
        end
        if ismissing(value)
            throw(DataFormatError("$(field_info.custom_name) value missing"))
        end
        if na_to_nothing && value == "NA"
            value = nothing
        end

        if !isnothing(value)
            if field_info.per_unit_conversion.From == IS.UnitSystem.NATURAL_UNITS &&
               field_info.per_unit_conversion.To == IS.UnitSystem.SYSTEM_BASE
                @debug "convert to $(field_info.per_unit_conversion.To)" _group =
                    IS.LOG_GROUP_PARSING field_info.custom_name
                value = value isa AbstractString ? tryparse(Float64, value) : value
                value = data.base_power == 0.0 ? 0.0 : value / data.base_power
            elseif field_info.per_unit_conversion.From == IS.UnitSystem.NATURAL_UNITS &&
                   field_info.per_unit_conversion.To == IS.UnitSystem.DEVICE_BASE
                reference_idx = findfirst(
                    x -> x.name == field_info.per_unit_conversion.Reference,
                    field_infos,
                )
                isnothing(reference_idx) && throw(
                    DataFormatError(
                        "$(field_info.per_unit_conversion.Reference) not found in table with $(field_info.custom_name)",
                    ),
                )
                reference_info = field_infos[reference_idx]
                @debug "convert to $(field_info.per_unit_conversion.To) using $(reference_info.custom_name)" _group =
                    IS.LOG_GROUP_PARSING field_info.custom_name maxlog = 1
                reference_value =
                    get(row, reference_info.custom_name, reference_info.default_value)
                reference_value == "required" && throw(
                    DataFormatError(
                        "$(reference_info.name) is required for p.u. conversion",
                    ),
                )
                value = value isa AbstractString ? tryparse(Float64, value) : value
                value = reference_value == 0.0 ? 0.0 : value / reference_value
            elseif field_info.per_unit_conversion.From != field_info.per_unit_conversion.To
                throw(
                    DataFormatError(
                        "conversion not supported from $(field_info.per_unit_conversion.From) to $(field_info.per_unit_conversion.To) for $(field_info.custom_name)",
                    ),
                )
            end
        else
            @debug "$(field_info.custom_name) is nothing" _group = IS.LOG_GROUP_PARSING maxlog =
                1
        end

        # TODO: need special handling for units
        if !isnothing(field_info.unit_conversion)
            @debug "convert units" _group = IS.LOG_GROUP_PARSING field_info.custom_name maxlog =
                1
            value = convert_units!(value, field_info.unit_conversion)
        end
        # TODO: validate ranges and option lists
        push!(fields, field_info.name)
        push!(vals, value)
    end
    return NamedTuple{Tuple(Symbol.(fields))}(vals)
end
