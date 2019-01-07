using HDF5, MAT

makesets(hourinfo) = makesets([:NOR, :FRA, :GER, :UK, :MED, :BAL, :SPA, :CEN, :CH_N, :CH_NE, :CH_E, :CH_SC, :CH_SW, :CH_NW], hourinfo)
makesets(r::Symbol, hourinfo) = makesets([r], hourinfo)

function makesets(REGION::Vector{Symbol}, hourinfo)
	techdata = Dict(
		:name => [:pv,  :csp, :wind, :offwind, :hydro,	  :coal,    :gasGT,   :gasCCGT, :bioGT,   :bioCCGT, :nuclear, :battery],
		:type => [:vre,	:vre, :vre,  :vre,     :storage,  :thermal, :thermal, :thermal, :thermal, :thermal, :thermal, :storage],
		:fuel => [:_,   :_,	  :_,    :_,       :_,        :coal,    :gas,     :gas,     :biogas,  :biogas,  :uranium, :_]
	)
	nstorageclasses = (4,4)		# (cost classes, reservoir classes)
	nvreclasses = 5

	numtechs = length(techdata[:name])
	reservoirs = collect('a':'z')[1:nstorageclasses[2]]
	vreclass = [Symbol("$letter$number") for letter in ["a", "b"] for number = 1:nvreclasses]
	hydroclass = [:x0;  [Symbol("$letter$number") for letter in reservoirs for number = 1:nstorageclasses[1]]]
	noclass = [:_]
	techtype = Dict(techdata[:name][i] => techdata[:type][i] for i=1:numtechs)
	techfuel = Dict(techdata[:name][i] => techdata[:fuel][i] for i=1:numtechs)

	TECH = techdata[:name]
	FUEL = [:_, :coal, :gas, :biogas, :uranium]
	CLASS = Dict(k => k == :hydro ? hydroclass : techtype[k] == :vre ? vreclass : noclass for k in TECH)
	CLASS[:transmission] = noclass
	STORAGECLASS = Dict(k => k == :hydro ? [:x0;  Symbol.(reservoirs)] : [:_] for k in TECH)

	reservoirclass = Dict(r => [Symbol("$r$number") for number = 1:nstorageclasses[1]] for r in Symbol.(reservoirs))
	reservoirclass[:x0] = [:x0]
	reservoirclass[:_] = [:_]

	HOUR = 1:Int(length(hourinfo.hourindexes)/hourinfo.sampleinterval)		# later use hoursperyear() in helperfunctions

	return Sets(REGION, FUEL, TECH, CLASS, STORAGECLASS, HOUR, techtype, techfuel, reservoirclass)
end

# resample hour dimension of array a (indicated by hourdim) using hourindexes in hourinfo structure,
# then reduce hours further by sampleinterval
function reducehours(a, hourdim, hourinfo)
	sampleinterval = hourinfo.sampleinterval
	aa = copy(selectdim(a, hourdim, hourinfo.hourindexes))
	out = copy(selectdim(aa, hourdim, 1:sampleinterval:size(aa,hourdim)))	# sample every nth hour
	if true		# true: averaging   false: sampling
		for i = 2:sampleinterval
			out += copy(selectdim(aa, hourdim, i:sampleinterval:size(aa,hourdim)))
		end
		out = out / sampleinterval
	end
	return out
end

# reduce regions from 10 (in Lina's input data) to 8 (in model)
# :MED = :IT + :GR,    :BAL (new) = :BAL (old) + :POL
function ten2eight(a)
	# REG10 = [:NOR, :IT, :FRA, :GER, :UK, :GR, :BAL, :POL, :SPA, :CEN]
	# REGION = [:NOR, :FRA, :GER, :UK, :MED, :BAL, :SPA, :CEN]
	out = a[[1,3,4,5,6,7,9,10],:]
	out[5,:] = a[2,:] + a[6,:]
	out[6,:] = a[7,:] + a[8,:]
	return out
end

CRF(r,T) = r / (1 - 1/(1+r)^T)

function makeparameters(sets, hourinfo)
	@unpack REGION, FUEL, TECH, CLASS, HOUR = sets

	year = 2016
	hoursperyear = 8760
	hoursperperiod = Int(hourinfo.hoursperperiod)

	discountrate = 0.05
	initialhydrostoragelevel = 0.7		# make this tech dependent later
	minflow_existinghydro = 0.4

	numregions = length(REGION)
	nhours = length(HOUR)
	nhydro = length(CLASS[:hydro])

	path = joinpath(dirname(@__FILE__), "..")

	# demand data is not currently based on same year as solar & wind data!!!
	file = h5open("$path/inputdata/demand_Europe10.h5", "r")
	readdemand::Matrix{Float64} = read(file, "demand")'/1000
	#distance = read(file, "distance")		# not used yet
	close(file)

	demand_EU = ten2eight(reducehours(readdemand, 2, hourinfo))
	
	# map China regions to Europe regions
	# [:NOR, :FRA, :GER, :UK, :MED, :BAL, :SPA, :CEN]	
	# [:North, :Northeast, :East, :SouthCentral, :Southwest, :Northwest]
	mapped = [1,6,8,3,2,7] #[:NOR, :BAL, :CEN, :GER, :FRA, :SPA]	
	demand_china = demand_EU[mapped,:]
	# China has one time zone 7 hours behind central Europe (6 during summer)
	# shift EU demand 6 hours (choose 6 rather than 7 because divisible by time periods 1,3,6)
	shiftperiods = 6 ÷ hoursperperiod
	demand_china[:,1:nhours] = [demand_china[:,shiftperiods+1:nhours] demand_china[:,1:shiftperiods]];

	# scale regional demand by population
	totaldemand = 6000/8760*1000		# GW	(6000 TWh/year = 685 GW)
	# [:North, :Northeast, :East, :SouthCentral, :Southwest, :Northwest]
	# https://en.wikipedia.org/wiki/List_of_regions_of_China
	population = [165, 110, 384, 384, 193, 97]						# Mpeople
	regionaldemand = totaldemand * population / sum(population)		# GW
	for r=1:6
		demand_china[r,:] = demand_china[r,:] / mean(demand_china[r,:]) * regionaldemand[r]
	end

	demand = AxisArray([demand_EU; demand_china], REGION, HOUR)		# GW

	hydrovars = matread("$path/inputdata/GISdata_hydro_eurochine14.mat")
	hydrocapacity = AxisArray(zeros(numregions,nhydro), REGION, CLASS[:hydro])
	hydroeleccost = AxisArray(zeros(numregions,nhydro), REGION, CLASS[:hydro])
	monthlyinflow = AxisArray(zeros(numregions,nhydro,12), REGION, CLASS[:hydro], 1:12)
	cfhydroinflow = AxisArray(zeros(numregions,nhydro,nhours), REGION, CLASS[:hydro], HOUR)
	dischargetime = AxisArray(zeros(numregions,2,1+nhydro), REGION, [:hydro,:battery], [CLASS[:hydro]; :_])
	
	hydrocapacity[:,:x0] = hydrovars["existingcapac"]
	hydrocapacity[:,2:end] = reshape(hydrovars["potentialcapac"], numregions, nhydro-1)
	hydrocapacity[isnan.(hydrocapacity)] = zeros(sum(isnan.(hydrocapacity)))

	# eleccost = capcost * crf / (CF * 8760)  =>   eleccost2/eleccost1 = crf2/crf1
	# 1$ = 0.9€ (average 2015-2017) 
	hydroeleccost[:,2:end] = reshape(hydrovars["potentialmeancost"], numregions, nhydro-1)		# $/kWh with 10% discount rate
	hydroeleccost[:,:] = hydroeleccost[:,:] * CRF(discountrate,40)/CRF(0.1,40) * 0.9 * 1000		# €/MWh    (0.9 €/$)
	hydroeleccost[isnan.(hydroeleccost)] = fill(999, sum(isnan.(hydroeleccost)))

	monthlyinflow[:,:x0,:] = hydrovars["existinginflowcf"]
	monthlyinflow[:,2:end,:] = reshape(hydrovars["potentialinflowcf"], numregions, nhydro-1, 12)
	monthlyinflow[isnan.(monthlyinflow)] = zeros(sum(isnan.(monthlyinflow)))

	hydrostoragecapacity = [	# TWh
		:NOR	:FRA	:GER	:UK		:MED	:BAL	:SPA	:CEN
		121.43	3.59	0		0		9.2		0		16.6	7.4
	]
	dischargetime[1:8,:hydro,:x0] = hydrostoragecapacity[2,:]./hydrocapacity[1:8,:x0] * 1000
	dischargetime[[:GER,:UK,:BAL],:hydro,:x0] .= 300
	dischargetime[9:14,:hydro,:x0] .= 168*6		# assume average discharge time 6 weeks for existing hydro in China
	dischargetime[:,:hydro,2:end-1] = reshape(hydrovars["potentialmeandischargetime"], numregions, nhydro-1)
	dischargetime[:,:battery,:_] .= 8
	dischargetime[isnan.(dischargetime)] = fill(10000, sum(isnan.(dischargetime)))
	dischargetime[dischargetime .> 10000] = fill(10000, sum(dischargetime .> 10000))

	# monthly to hourly hydro inflow
	dayspermonth = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
	lasthour = 24 ÷ hoursperperiod * cumsum(dayspermonth)
	firsthour = [1; 1 .+ lasthour[1:end-1]]
	for m = 1:12
		for i = firsthour[m]:lasthour[m]
			cfhydroinflow[:,:,i] = monthlyinflow[:,:,m]
		end
	end
	cfhydroinflow[cfhydroinflow .< 0.01] = zeros(sum(cfhydroinflow .< 0.01))

	transmissioncostdata_eu = [	# €/kW
		:_		:NOR	:FRA	:GER	:UK		:MED	:BAL	:SPA	:CEN
		:NOR	0		0		600		1200	0		1000	0		0
		:FRA	0		0		500		600		1200	0		500		1000
		:GER	600		500		0		900		0		500		0		400
		:UK		1200	600		900		0		0		0		0		0
		:MED	0		1200	0		0		0		0		0		650
		:BAL	1000	0		500		0		0		0		0		400
		:SPA	0		500		0		0		0		0		0		0
		:CEN	0		1000	400		0		650		400		0		0
	]
	transmissioncostdata_china = [	# €/kW
		:_				:CH_N   :CH_NE    :CH_E    :CH_SC    :CH_SW    :CH_NW
		:CH_N			0        1000      1000     1000      1500      1500
		:CH_NE          1000     0         1500     0         0         0
		:CH_E           1000     1500      0        800       1500      1800
		:CH_SC          1000     0         800      0         1000      1500
		:CH_SW          1500     0         1500     1000      0         1200
		:CH_NW          1500     0         1800     1500      1200      0
	]
	transmissioncostdata = zeros(numregions,numregions)
	transmissioncostdata[1:8,1:8] = transmissioncostdata_eu[2:end,2:end]
	transmissioncostdata[9:14,9:14] = transmissioncostdata_china[2:end,2:end]
	transmissioncostdata[3,12] = transmissioncostdata[12,3] = 3000
	transmissioncost = AxisArray(transmissioncostdata, REGION, REGION)		# €/kW
	transmissionlosses = AxisArray(fill(0.05,numregions,numregions), REGION, REGION)		# maybe proportional to distance (costs) later?
	transmissionlosses[9:14,9:14] .= 0.10
	transmissionlosses[3,12] = transmissionlosses[12,3] = 0.15
	smalltransmissionpenalty = 0.1		# €/MWh elec

	investdata = [
		#				investcost	variablecost	fixedcost	lifetime	efficiency	rampingrate
		#				€/kW		€/MWh elec		€/kW/year	years					share of capacity per hour
		:gasGT			380			0.7				50			30			0.4			1
		:gasCCGT		760			0.8				50			30			0.7			0.3
		:coal			1400		0				80			35			0.4			0.15
		:bioGT			380			0.7				50			30			0.4			1
		:bioCCGT		760			0.8				50			30			0.7			0.3
		:nuclear		5100		0				160			60			0.4			0.05
		:wind			1400		0				44			25			1			1
		:offwind		2000		0				100			25			1			1
		:transmission	NaN			0				0			40			NaN			1
		:battery		1200		0				0			10			0.85		1	# 8h discharge time, 1200 €/kW = 150 €/kWh
		:pv				600			0				19			25			1			1
		:csp			1200		0				50			30			1			1	# add CSP data later
		# :hydroRoR and :hydroDam are sunk costs
		:hydro			10			0				0			80			1			1	# small artificial investcost so it doesn't overinvest in free capacity 
		# :hydroRoR		0			0				0			80			1
		# :hydroDam		0			0				0			80			1				# change hydroDam efficiency later
	]
	investtechs = investdata[:,1]
	investdata = Float64.(investdata[:,2:end])
	baseinvestcost = AxisArray(investdata[:,1], investtechs)	# €/kW
	variablecost = AxisArray(investdata[:,2], investtechs)	# €/MWh elec
	fixedcost = AxisArray(investdata[:,3], investtechs)		# €/kW/year
	lifetime = AxisArray(investdata[:,4], investtechs)		# years
	efficiency = AxisArray(investdata[:,5], investtechs)
	rampingrate = AxisArray(investdata[:,6], investtechs)
	# rampingrate[:] .= 1										# disable all ramping constraints

	fuelcost = AxisArray(Float64[0, 8, 30, 60, 8], [:_, :coal, :gas, :biogas, :uranium])		# €/MWh fuel

	crf = AxisArray(discountrate ./ (1 .- 1 ./(1+discountrate).^lifetime), investtechs)

	emissionsCO2 = AxisArray(zeros(length(FUEL)), FUEL)
	emissionsCO2[[:coal,:gas]] = [0.330, 0.202]		# kgCO2/kWh fuel (or ton/MWh or kton/GWh)

	# do something with B classes (and pvrooftop) later
	windvars = matread("$path/inputdata/GISdata_wind2016_eurochine14.mat")
	solarvars = matread("$path/inputdata/GISdata_solar2016_eurochine14.mat")
	# windvars = matread("$path/inputdata/GISdata_wind2016_1000km_eurochine14.mat")
	# solarvars = matread("$path/inputdata/GISdata_solar2016_1000km_eurochine14.mat")

	allclasses = union(sets.CLASS[:pv], sets.CLASS[:hydro], [:_])
	cf = AxisArray(ones(numregions,length(TECH),length(allclasses),nhours), REGION, TECH, allclasses, HOUR)
	capacitylimits = AxisArray(zeros(numregions,4,length(CLASS[:pv])), REGION, [:wind, :offwind, :pv, :csp], CLASS[:pv])

	# sync wind & solar time series with demand
	# (ignore 2016 extra leap day for now, fix this later)
	# note first wind data is at 00:00 and first solar data is at 07:00
	# assume first demand data is at 00:00
	cf[:,:wind,1:5,:] = permutedims(reducehours(windvars["CFtime_windonshoreA"][25:hoursperyear+24,:,:], 1, hourinfo), [2,3,1])
	cf[:,:offwind,1:5,:] = permutedims(reducehours(windvars["CFtime_windoffshore"][25:hoursperyear+24,:,:], 1, hourinfo), [2,3,1])
	cf[:,:pv,1:5,:] = permutedims(reducehours(solarvars["CFtime_pvplantA"][18:hoursperyear+17,:,:], 1, hourinfo), [2,3,1])
	cf[:,:csp,1:5,:] = permutedims(reducehours(solarvars["CFtime_cspplantA"][18:hoursperyear+17,:,:], 1, hourinfo), [2,3,1])
	cf[:,:wind,6:10,:] = permutedims(reducehours(windvars["CFtime_windonshoreB"][25:hoursperyear+24,:,:], 1, hourinfo), [2,3,1])
	cf[:,:pv,6:10,:] = permutedims(reducehours(solarvars["CFtime_pvplantB"][18:hoursperyear+17,:,:], 1, hourinfo), [2,3,1])
	cf[:,:csp,6:10,:] = permutedims(reducehours(solarvars["CFtime_cspplantB"][18:hoursperyear+17,:,:], 1, hourinfo), [2,3,1])
	cf[isnan.(cf)] = zeros(sum(isnan.(cf)))
	cf[cf .< 0.01] = zeros(sum(cf .< 0.01))		# set small values to 0 for better numerical stability

	capacitylimits[:,:wind,1:5] = windvars["capacity_onshoreA"]
	capacitylimits[:,:offwind,1:5] = windvars["capacity_offshore"]
	capacitylimits[:,:pv,1:5] = solarvars["capacity_pvplantA"]
	capacitylimits[:,:csp,1:5] = solarvars["capacity_cspplantA"]
	capacitylimits[:,:wind,6:10] = windvars["capacity_onshoreB"]
	capacitylimits[:,:pv,6:10] = solarvars["capacity_pvplantB"]
	capacitylimits[:,:csp,6:10] = solarvars["capacity_cspplantB"]

	investcost = AxisArray(zeros(length(investtechs),length(allclasses)), investtechs, allclasses)	# €/kW
	for k in investtechs, c in CLASS[k]
		investcost[k,c] = baseinvestcost[k]
	end
	for k in [:wind,:pv,:csp]
		investcost[k,6:10] .= baseinvestcost[k]*1.1
	end

	return Params(cf, transmissionlosses, demand, hydrocapacity, cfhydroinflow, capacitylimits,
		efficiency, rampingrate, dischargetime, initialhydrostoragelevel, minflow_existinghydro, emissionsCO2,
		fuelcost, variablecost, smalltransmissionpenalty, investcost, crf, fixedcost, transmissioncost, hydroeleccost)
end
