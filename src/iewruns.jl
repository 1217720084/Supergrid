using Plots, JLD2, FileIO, Plots.PlotMeasures

plotly()

function IEWruns1(hourinterval)
	resultslist = Dict()
	allstatus = Dict()
	runcount = 0
	for nuc in [false]
		for solarwind in [1, 4]
			for tm in [:none, :islands, :all]
				for cap in [1, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0.002, 0.001, 0]
					# runcount += 1
					# runcount in [1] && continue
					println("\n\n\nNew run: nuclear=$nuc, solarwind=$solarwind, transmission=$tm, cap=$cap.")
					model = buildmodel(hours=hourinterval, carboncap=cap, maxbiocapacity=0.05, 
										nuclearallowed=nuc, hydroinvestmentsallowed=true, transmissionallowed=tm, solarwindarea=solarwind)
					println("\nSolving model...")
					status = solve(model.modelname)
					println("\nSolve status: $status")
					resultslist[nuc,solarwind,tm,cap] = sum(getvalue(model.vars.Systemcost))
					allstatus[nuc,solarwind,tm,cap] = status
					@save "iewcosts1_hydro.jld2" resultslist allstatus
					println("\nReading results...")
					results = readresults(model, status)
					name = autorunname(model.options)
					println("\nSaving results to disk...")
					saveresults(results, name, filename="iewruns1_hydro.jld2")
				end
			end
		end
	end
	resultslist, allstatus
end

function IEWruns2(hourinterval)
	resultslist = Dict()
	allstatus = Dict()
	for nuc in [false]
		for solarwind in [4]
			for tm in [:islands, :all]
				for cap in [0.001]
					options, hourinfo, sets, params = buildsetsparams(hours=hourinterval, carboncap=cap, maxbiocapacity=0.05,
											solarwindarea=solarwind, nuclearallowed=nuc, transmissionallowed=tm)
					pvcost = params.investcost[:pv,:a1]
					pvroofcost = params.investcost[:pvroof,:a1]
					batterycost = params.investcost[:battery,:_]
					for solar in [:high, :mid, :low]
						for battery in [:high, :mid, :low]
							println("\n\n\nNew run: nuclear=$nuc, solarwind=$solarwind, transmission=$tm, cap=$cap, solar=$solar, battery=$battery.")
							for c in sets.CLASS[:pv]
								if solar == :high
									params.investcost[:pv,c] = pvcost * 1.5
									params.investcost[:pvroof,c] = pvroofcost + pvcost * 0.5
								elseif solar == :mid
									params.investcost[:pv,c] = pvcost
									params.investcost[:pvroof,c] = pvroofcost
								elseif solar == :low
									params.investcost[:pv,c] = pvcost * 0.5
									params.investcost[:pvroof,c] = pvroofcost - pvcost * 0.5
								end
							end
							if battery == :high
								params.investcost[:battery,:_] = batterycost * 1.5
							elseif battery == :mid
								params.investcost[:battery,:_] = batterycost
							elseif battery == :low
								params.investcost[:battery,:_] = batterycost * 0.5
							end
							model = buildvarsmodel(options, hourinfo, sets, params)
							println("\nSolving model...")
							status = solve(model.modelname)
							println("\nSolve status: $status")
							resultslist[solarwind,tm,cap,solar,battery] = sum(getvalue(model.vars.Systemcost))
							allstatus[solarwind,tm,cap,solar,battery] = status
							@save "iewcosts2.jld2" resultslist allstatus
							println("\nReading results...")
							results = readresults(model, status)
							name = autorunname(model.options) * ", solarwind=$solarwind, solar=$solar, battery=$battery"
							println("\nSaving results to disk...")
							saveresults(results, name, filename="iewruns2.jld2")
						end
					end
				end
			end
		end
	end
	resultslist, allstatus
end

function IEWruns3(hourinterval)
	results = Dict()
	allstatus = Dict()
	for bio in [0, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3]
		for tm in [:islands, :all]
			for cap in [0.005, 0]
				println("\n\n\nNew run: bio=$bio, transmission=$tm, cap=$cap.")
				model = buildmodel(hours=hourinterval, carboncap=cap, maxbiocapacity=bio, 
									nuclearallowed=false, transmissionallowed=tm)
				println("\nSolving model...")
				status = solve(model.modelname)
				println("\nSolve status: $status")
				results[bio,tm,cap] = sum(getvalue(model.vars.Systemcost))
				allstatus[bio,tm,cap] = status
				@save "iewruns3_$(hourinterval)h.jld2" results allstatus
			end
		end
	end
	results, allstatus
end

function mergeresults()
	# @load "iewcosts1_0.jld2" resultslist allstatus
	# res0, st0 = resultslist, allstatus
	# @load "iewcosts1.jld2" resultslist allstatus
	# resultslist[false, 1, :none, 1.0] = res0[false, 1, :none, 1.0] 
	# allstatus[false, 1, :none, 1.0] = st0[false, 1, :none, 1.0] 
	# @save "iewcosts1.jld2" resultslist allstatus
	@load "iewcosts2 - part1.jld2" resultslist allstatus
	res1, st1 = resultslist, allstatus
	@load "iewcosts2 - part2.jld2" resultslist allstatus
	res2, st2 = resultslist, allstatus
	resultslist = merge(res1, res2)
	allstatus = merge(st1, st2)
	@save "iewcosts2.jld2" resultslist allstatus
end

function plotiew_lines_v2()
	totaldemand = 1.8695380613113698e7	# (GWh/yr) r = loadresults("nuclearallowed=false", filename="iewruns1.jld2");  sum(r.params[:demand])
	@load "iewcosts1.jld2" resultslist allstatus
	res = resultslist
	carboncaps = [1000; 200; 100; 50; 20; 10; 5; 2; 1; 0]	
	res0 = get(res,(true,1,:all,1),0)
	if res0 == 0
		res0 = get(res,(false,1,:all,1),0)
		res0 == 0 && error("No results for base case!")
	end
	function getresults(a,b,c,d)
		cost = get(res,(a,b,c,d),NaN)						# M€/year
		return cost > 1e7 ? NaN : cost/totaldemand*1000		# €/MWh
	end
	resmat1 = [getresults(true,1,tm,cap/1000) for cap in carboncaps, tm in [:none, :islands, :all]]
	resmat2 = [getresults(false,1,tm,cap/1000) for cap in carboncaps, tm in [:none, :islands, :all]]
	resmat3 = [getresults(true,4,tm,cap/1000) for cap in carboncaps, tm in [:none, :islands, :all]]
	resmat4 = [getresults(false,4,tm,cap/1000) for cap in carboncaps, tm in [:none, :islands, :all]]
	p1 = plot(string.(carboncaps), resmat1, title="nuclear, default solar & wind area")
	p2 = plot(string.(carboncaps), resmat2, title="no nuclear, default solar & wind area")
	p3 = plot(string.(carboncaps), resmat3, title="nuclear, high solar & wind area")
	p4 = plot(string.(carboncaps), resmat4, title="no nuclear, high solar & wind area")
	display(plot(p2, p4, layout=2, size=(1850,950), ylim=(0,120), label=[:none :islands :all], line=3, tickfont=16, legendfont=16,
					titlefont=20, guidefont=16, xlabel="Global CO2 cap [g CO2/kWh]", ylabel="Average system cost [€/MWh]"))
	# display(plot(p3, p4, layout=2, size=(1850,950), ylim=(0.9,2.5), label=[:none :islands :all], line=3, tickfont=16, legendfont=16,
	# 				titlefont=20, guidefont=16, xlabel="g CO2/kWh", ylabel="relative cost"))
end

function plotiew_lines_hydro()
	@load "iewcosts1.jld2" resultslist allstatus
	res = resultslist
	carboncaps = [1000; 200; 100; 50; 20; 10; 5; 2; 1; 0]	
	res0 = get(res,(true,1,:all,1),0)
	if res0 == 0
		res0 = get(res,(false,1,:all,1),0)
		res0 == 0 && error("No results for base case!")
	end
	@load "iewcosts1_hydro.jld2" resultslist allstatus
	resh = resultslist
	function getresults(res,a,b,c,d)
		out = get(res,(a,b,c,d),NaN)
		return out > 1e7 ? NaN : out/res0
	end
	resmat1 = [getresults(res,false,1,tm,cap/1000) for cap in carboncaps, tm in [:none, :islands, :all]]
	resmat2 = [getresults(resh,false,1,tm,cap/1000) for cap in carboncaps, tm in [:none, :islands, :all]]
	p1 = plot(string.(carboncaps), resmat1, title="no nuclear, existing hydro")
	p2 = plot(string.(carboncaps), resmat2, title="no nuclear, existing hydro + investments")
	display(plot(p1, p2, layout=2, size=(1850,950), ylim=(0.9,2.5), label=[:none :islands :all], line=3, tickfont=16, legendfont=16,
					titlefont=20, guidefont=16, xlabel="Global CO2 constraint [g CO2/kWh]", ylabel="relative cost"))
end

# using JLD2, Plots; @load "iewruns1_1h.jld2" results allstatus; plotly()
function plotiew_lines_v1()
	totaldemand = 1.8695380613113698e7	# (GWh/yr) r = loadresults("nuclearallowed=false", filename="iewruns1.jld2");  sum(r.params[:demand])
	@load "iewruns1_1h.jld2" results allstatus
	res = results
	carboncaps = [1000; 200; 100; 50; 20; 10; 5; 2; 1; 0]	
	res0 = res[true,:all,1]
	resmat1 = [res[true,tm,cap/1000]/totaldemand*1000 for cap in carboncaps, tm in [:none, :islands, :all]]
	resmat2 = [res[false,tm,cap/1000]/totaldemand*1000 for cap in carboncaps, tm in [:none, :islands, :all]]
	p1 = plot(string.(carboncaps), resmat1, title="nuclear")
	p2 = plot(string.(carboncaps), resmat2, title="no nuclear")
	display(plot(p1, p2, layout=2, size=(1850,950), ylim=(0,120), label=[:none :islands :all], line=3, tickfont=16, legendfont=16,
					titlefont=20, guidefont=16, xlabel="Global CO2 cap [g CO2/kWh]", ylabel="Average system cost [€/MWh]"))
end

function plotiew_lines1_paper()
	totaldemand = 1.8695380613113698e7	# (GWh/yr) r = loadresults("nuclearallowed=false", filename="iewruns1.jld2");  sum(r.params[:demand])
	@load "iewruns1_1h.jld2" results allstatus
	res = results
	carboncaps = Any[1000; 200; 100; 50; 20; 10; 5; 2; 1]	
	res0 = res[true,:all,1]
	resmat1 = [res[true,tm,cap/1000]/totaldemand*1000 for cap in carboncaps, tm in [:islands, :all]]
	resmat2 = [res[false,tm,cap/1000]/totaldemand*1000 for cap in carboncaps, tm in [:islands, :all]]
	carboncaps[1] = "none"
	display([resmat2 resmat1])
	p = plot(string.(carboncaps), [resmat2 resmat1], color=[1 2 1 2], line=[:solid :solid :dash :dash])
	display(plot(p, size=(1000,450), ylim=(0,70), 
					label=["Is-lowL - no nuclear" "Sup-lowL - no nuclear" "Is-lowL - unlimited nuclear" "Sup-lowL - unlimited nuclear"],
					line=3, tickfont=14, legendfont=14,
					titlefont=16, guidefont=14, xlabel="Global CO2 cap [g CO2/kWh]", ylabel="Average system cost [€/MWh]",
					left_margin=50px, gridlinewidth=1))
end

function plotiew_lines2_paper()
	totaldemand = 1.8695380613113698e7	# (GWh/yr) r = loadresults("nuclearallowed=false", filename="iewruns1.jld2");  sum(r.params[:demand])
	@load "iewcosts1.jld2" resultslist allstatus
	res = resultslist
	carboncaps = Any[1000; 200; 100; 50; 20; 10; 5; 2; 1]	
	res0 = get(res,(true,1,:all,1),0)
	if res0 == 0
		res0 = get(res,(false,1,:all,1),0)
		res0 == 0 && error("No results for base case!")
	end
	function getresults(a,b,c,d)
		cost = get(res,(a,b,c,d),NaN)						# M€/year
		return cost > 1e7 ? NaN : cost/totaldemand*1000		# €/MWh
	end
	resmat1 = [getresults(true,1,tm,cap/1000) for cap in carboncaps, tm in [:islands, :all]]
	resmat2 = [getresults(false,1,tm,cap/1000) for cap in carboncaps, tm in [:islands, :all]]
	resmat3 = [getresults(true,4,tm,cap/1000) for cap in carboncaps, tm in [:islands, :all]]
	resmat4 = [getresults(false,4,tm,cap/1000) for cap in carboncaps, tm in [:islands, :all]]
	carboncaps[1] = "none"
	p1 = plot(string.(carboncaps), resmat1, title="Unlimited nuclear, default solar & wind area")
	p2 = plot(string.(carboncaps), resmat2, title="Low solar & wind area", label=["" ""])
	p3 = plot(string.(carboncaps), resmat3, title="Unlimited nuclear, high solar & wind area")
	p4 = plot(string.(carboncaps), resmat4, title="High solar & wind area", label=[:islands :all])

	p = plot(string.(carboncaps), [resmat2 resmat4], color=[1 2 1 2], line=[:solid :solid :dash :dash])
	display(plot(p, size=(850,450), ylim=(0,70), 
					label=["Is-lowL" "Sup-lowL" "Is-highL" "Sup-highL"],
					line=3, tickfont=14, legendfont=14,
					titlefont=16, guidefont=14, xlabel="Global CO2 cap [g CO2/kWh]", ylabel="Average system cost [€/MWh]",
					left_margin=50px, gridlinewidth=1))
	# p1 = plot(string.(carboncaps), resmat1, title="Unlimited nuclear, default solar & wind area")
	# p2 = plot(string.(carboncaps), resmat2, title="Low solar & wind area", label=["" ""])
	# p3 = plot(string.(carboncaps), resmat3, title="Unlimited nuclear, high solar & wind area")
	# p4 = plot(string.(carboncaps), resmat4, title="High solar & wind area", label=[:islands :all])
	# display(plot(p2, p4, layout=2, size=(1000,450), ylim=(0,70), line=3, tickfont=14, legendfont=14,
	# 				titlefont=16, guidefont=14, xlabel="Global CO2 cap [g CO2/kWh]", ylabel="Average system cost [€/MWh]",
	# 				left_margin=50px, gridlinewidth=1))
	# display(plot(p3, p4, layout=2, size=(1850,950), ylim=(0.9,2.5), label=[:none :islands :all], line=3, tickfont=16, legendfont=16,
	# 				titlefont=20, guidefont=16, xlabel="g CO2/kWh", ylabel="relative cost"))
end

function plotiew_bubbles_paper()
	@load "iewcosts2.jld2" resultslist allstatus
	res = resultslist
	rows = [3 3 3 2 2 2 1 1 1]
	cols = [3 2 1 3 2 1 3 2 1]
	r1 = [(res[1,:islands,0.001,solar,battery]-res[1,:all,0.001,solar,battery])/res[1,:all,0.001,solar,battery] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	r2 = [(res[4,:islands,0.001,solar,battery]-res[4,:all,0.001,solar,battery])/res[4,:all,0.001,solar,battery] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	annotations1 = [(rows[i]-0.17*r1[i]/0.06, cols[i], text("$(round(r1[i]*100, digits=1))%", :right)) for i=1:9]
	annotations2 = [(rows[i]-0.17*r2[i]/0.06, cols[i], text("$(round(r2[i]*100, digits=1))%", :right)) for i=1:9]
	s1 = scatter(rows, cols, markersize=reshape(r1*400, (1,9)), annotations=annotations1, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="Low solar & wind area", xlabel="battery cost", ylabel="solar PV cost", color=1,
					tickfont=14, guidefont=14)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	s2 = scatter(rows, cols, markersize=reshape(r2*400, (1,9)), annotations=annotations2, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="High solar & wind area", xlabel="battery cost", ylabel="solar PV cost", color=1,
					tickfont=14, guidefont=14, left_margin=20px)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	display(plot(s1, s2, layout=2, size=(1000,450)))
end

function plotiew_energymix(scenelec, demands, hoursperperiod, displayorder, techlabels)
	scen = ["Is-lowL", "Sup-lowL", "Is-highL", "Sup-highL"]
	resultsnames = ["transmissionallowed=islands, nuclearallowed=false, carboncap=0.001",
					"nuclearallowed=false, carboncap=0.001",
					"transmissionallowed=islands, nuclearallowed=false, carboncap=0.001, solarwindarea=4",
					"nuclearallowed=false, carboncap=0.001, solarwindarea=4"]
	
	# scenelec, demands, hoursperperiod, displayorder, techlabels = getscenresults(scen, resultsnames)

	palette = [RGB([216,137,255]/255...), RGB([119,112,71]/255...), RGB([199,218,241]/255...), RGB([149,179,215]/255...),
		RGB([255,255,64]/255...), RGB([240,224,0]/255...), RGB([214,64,64]/255...), RGB([255,192,0]/255...), RGB([99,172,70]/255...),
		RGB([100,136,209]/255...), RGB([144,213,93]/255...), RGB([148,138,84]/255...), RGB([157,87,205]/255...)]
	groupedbarflip(collect(scenelec[displayorder,:]')/1e6, label=techlabels, bar_position = :stack, size=(600,550),
			left_margin=20px, xticks=(1:4,scen), line=0, tickfont=12, legendfont=12, guidefont=12, color_palette=palette, ylabel="[PWh/year]")
	xpos = (1:4)'
	display(plot!([xpos; xpos], [zeros(4)'; demands'*hoursperperiod/1e6], line=3, color=:black, label=["demand" "" "" ""]))
	nothing
end

function readscenariodata(resultname)
	results = loadresults(resultname, filename="iewruns1.jld2")
	@unpack TECH, REGION, CLASS, HOUR = results.sets
	hoursperperiod = results.hourinfo.hoursperperiod
	totaldemand = sum(results.params[:demand])
	totalelec = [sum(sum(results.Electricity[k,c]) for c in CLASS[k]) for k in TECH]

	displaytechs = [:nuclear, :coal, :wind, :offwind, :pv, :pvroof, :csp, :gasCCGT, :bioCCGT, :hydro, :bioGT, :gasGT, :battery]
	techlabels = [k for r=1:1, k in displaytechs]
	displayorder = [i for (i,k) in enumerate(TECH), d in displaytechs if d == k]

	return totalelec, totaldemand, hoursperperiod, displayorder, techlabels
end

function getscenresults(scen, resultsnames)
	scenelec = zeros(13,length(scen))
	demands = zeros(length(scen))
	hoursperperiod, displayorder, techlabels = nothing, nothing, nothing

	for (i,s) in enumerate(scen)
		println("Loading results: $s...")
		totalelec, totaldemand, hoursperperiod, displayorder, techlabels = readscenariodata(resultsnames[i])
		scenelec[:,i] = totalelec
		demands[i] = totaldemand
	end
	return scenelec, demands, hoursperperiod, displayorder, techlabels
end

function plotiew_bubbles_v1()
	@load "iewruns2_1h.jld2" results allstatus
	res = results
	rows = [3 3 3 2 2 2 1 1 1]
	cols = [3 2 1 3 2 1 3 2 1]
	r = [(res[false,:islands,0.005,solar,battery]-res[false,:all,0.005,solar,battery])/res[false,:all,0.005,solar,battery] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	annotations = [(rows[i]-0.17*r[i]/0.06, cols[i], text("$(round(r[i]*100, digits=1))%", :right)) for i=1:9]
	s = scatter(rows, cols, markersize=reshape(r*500, (1,9)), annotations=annotations, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="System cost diff: islands - all (no nuclear)", xlabel="battery cost", ylabel="solar PV cost",
					tickfont=12, guidefont=12)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	display(s)
end

function plotiew_bubbles_v2()
	@load "iewcosts2.jld2" resultslist allstatus
	res = resultslist
	rows = [3 3 3 2 2 2 1 1 1]
	cols = [3 2 1 3 2 1 3 2 1]
	r1 = [(res[1,:islands,0.001,solar,battery]-res[1,:all,0.001,solar,battery])/res[1,:all,0.001,solar,battery] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	r2 = [(res[4,:islands,0.001,solar,battery]-res[4,:all,0.001,solar,battery])/res[4,:all,0.001,solar,battery] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	annotations1 = [(rows[i]-0.17*r1[i]/0.06, cols[i], text("$(round(r1[i]*100, digits=1))%", :right)) for i=1:9]
	annotations2 = [(rows[i]-0.17*r2[i]/0.06, cols[i], text("$(round(r2[i]*100, digits=1))%", :right)) for i=1:9]
	s1 = scatter(rows, cols, markersize=reshape(r1*500, (1,9)), annotations=annotations1, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="System cost diff: islands - all (default solar/wind area)", xlabel="battery cost", ylabel="solar PV cost",
					tickfont=12, guidefont=12)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	s2 = scatter(rows, cols, markersize=reshape(r2*500, (1,9)), annotations=annotations2, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="System cost diff: islands - all (high solar/wind area)", xlabel="battery cost", ylabel="solar PV cost",
					tickfont=12, guidefont=12)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	display(plot(s1, s2, layout=2, size=(1350,650)))
end

function plotiew_bubbles_v2_abs()
	totaldemand = 1.8695380613113698e7	# (GWh/yr) r = loadresults("nuclearallowed=false", filename="iewruns1.jld2");  sum(r.params[:demand])
	@load "iewcosts2.jld2" resultslist allstatus
	res = resultslist
	rows = [3 3 3 2 2 2 1 1 1]
	cols = [3 2 1 3 2 1 3 2 1]
	r1 = [(res[1,:islands,0.001,solar,battery]-res[1,:all,0.001,solar,battery])/totaldemand*1000 for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	r2 = [(res[4,:islands,0.001,solar,battery]-res[4,:all,0.001,solar,battery])/totaldemand*1000 for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
	annotations1 = [(rows[i]-0.06*r1[i], cols[i], text("$(round(r1[i], digits=1))", :right)) for i=1:9]
	annotations2 = [(rows[i]-0.06*r2[i], cols[i], text("$(round(r2[i], digits=1))", :right)) for i=1:9]
	s1 = scatter(rows, cols, markersize=reshape(r1*10, (1,9)), annotations=annotations1, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="System cost diff [€/MWh]: islands - all (default solar/wind area)", xlabel="battery cost", ylabel="solar PV cost",
					tickfont=12, guidefont=12)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	s2 = scatter(rows, cols, markersize=reshape(r2*10, (1,9)), annotations=annotations2, xlim=(0.5,3.5), ylim=(0.5,3.5), legend=false,
					title="System cost diff [€/MWh]: islands - all (high solar/wind area)", xlabel="battery cost", ylabel="solar PV cost",
					tickfont=12, guidefont=12)
	xticks!([1,2,3],["low","mid","high"])
	yticks!([1,2,3],["low","mid","high"])
	display(plot(s1, s2, layout=2, size=(1350,650)))
end

function plotiew_biolines_v1()
	@load "iewruns1_1h.jld2" results allstatus
	res0 = results[true,:all,1]
	@load "iewruns3_1h.jld2" results allstatus
	res = results
	carboncaps = [5; 0]
	allbio = [0, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.3]
	res_islands = [res[bio,:islands,cap/1000]/res0 for cap in carboncaps, bio in allbio]
	res_all = [res[bio,:all,cap/1000]/res0 for cap in carboncaps, bio in allbio]
	# p1 = plot(string.(carboncaps), res_islands, title="islands")
	# p2 = plot(string.(carboncaps), res_all, title="all")
	# display(plot(p1, p2, layout=2, size=(1850,950), ylim=(0.9,2.5), label=biolabels, line=3, tickfont=16, legendfont=16,
	# 				titlefont=20, guidefont=16, xlabel="g CO2/kWh", ylabel="relative cost"))
	biolabels_islands = ["bio=$b, islands" for i in 1:1, b in allbio]
	biolabels_all = ["bio=$b, all" for i in 1:1, b in allbio]
	p = plot(string.(carboncaps), res_islands, size=(650,950), ylim=(0.9,2.5), label=biolabels_islands, line=(3,:dash), tickfont=16, legendfont=16,
					color=reshape(1:8,(1,8)), titlefont=20, guidefont=16, xlabel="g CO2/kWh", ylabel="relative cost")
	plot!(string.(carboncaps), res_all, color=reshape(1:8,(1,8)), label=biolabels_all, line=3)
	display(p)
end

# function plotiew1_v2(res)
# 	carboncaps = [1; 0.2; 0.1; 0.05; 0.02; 0.01; 0.005; 0.002; 0.001; 0]	
# 	res0 = res[true,:all,1]
# 	resmat1 = [res[true,tm,cap]/res0 for cap in carboncaps, tm in [:none, :islands, :all]]
# 	resmat2 = [res[false,tm,cap]/res0 for cap in carboncaps, tm in [:none, :islands, :all]]
# 	plot(string.(carboncaps), [resmat2 resmat1], size=(1850,950), label=[:none_nonuke :islands_nonuke :all_nonuke :none :islands :all],
# 		line=3, tickfont=16, legendfont=16, titlefont=20, guidefont=16, xlabel="g CO2/kWh", ylabel="relative cost")
# end

# function plotiew2_old(res)
# 	row = [1 1 1; 2 2 2; 3 3 3]
# 	col = [1 2 3; 1 2 3; 1 2 3]
# 	# row = [solar for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
# 	# col = [battery for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
# 	resmat1 = [(res[true,:islands,0.005,solar,battery]-res[true,:all,0.005,solar,battery])/res[true,:all,0.005,:low,:low] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
# 	resmat2 = [(res[false,:islands,0.005,solar,battery]-res[false,:all,0.005,solar,battery])/res[true,:all,0.005,:low,:low] for solar in [:high, :mid, :low], battery in [:high, :mid, :low]]
# 	display(resmat1)
# 	println()
# 	display(resmat2)
# 	display(scatter(row, col, markersize=resmat1*100, title="nuclear"))
# 	display(scatter(row, col, markersize=resmat2*100, title="no nuclear"))
# end



#=
for nuc in [false, true], tm in [:none, :islands, :all], cap in [1, 0.2, 0.1, 0.05, 0.02, 0.01, 0.005, 0]
   s = allstatus[nuc,tm,cap]
   s != :Optimal && println("$nuc, $tm, $cap: $s")
end

results[false,:all,0.1] = 0.5*(8.5223549e+05 + 8.5223282e+05)
results[true,:none,0.01] = 0.5*(9.5207609e+05 + 9.5207205e+05)
results[true,:none,0.005] = 0.5*(9.6381845e+05 + 9.6381386e+05)
results[true,:islands,0.01] = 0.5*(9.2467909e+05 + 9.2467558e+05)

results[false,:islands,0.005,:high,:low] = 0.5*(1.1262351e+06 + 1.1262346e+06)
results[false,:all,0.005,:mid,:high] = 0.5*(1.1611178e+06 + 1.1611177e+06)
results[false,:all,0.005,:mid,:mid] = 0.5*(1.0995099e+06 + 1.0995086e+06)
results[false,:all,0.005,:low,:high] = 0.5*(1.0677177e+06 + 1.0677151e+06)

=#