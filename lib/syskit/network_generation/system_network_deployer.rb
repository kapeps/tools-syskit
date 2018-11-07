module Syskit
    module NetworkGeneration
        # Algorithm that transforms a network generated by
        # {SystemNetworkGenerator} into a deployed network
        #
        # It does not deal with adapting an existing network
        class SystemNetworkDeployer
            extend Logger::Hierarchy
            include Logger::Hierarchy
            include Roby::DRoby::EventLogging

            # The plan this deployer is acting on
            #
            # @return [Roby::Plan]
            attr_reader :plan

            # An event logger object used to track execution
            #
            # @see {Roby::DRoby::EventLogging}
            attr_reader :event_logger

            # The solver used to track the deployed tasks vs. the original tasks
            #
            # @return [MergeSolver]
            attr_reader :merge_solver

            # The deployment group used by default
            #
            # Each subpart of the network can specify their own through
            # {Component#requirements}, in which case the new group is
            # merged into the default
            #
            # @return [Models::DeploymentGroup]
            attr_accessor :default_deployment_group

            def initialize(plan, event_logger: plan.event_logger,
                    merge_solver: MergeSolver.new(plan),
                    default_deployment_group: Syskit.conf.deployment_group)

                @plan = plan
                @event_logger = event_logger
                @merge_solver = merge_solver
                @default_deployment_group = default_deployment_group
            end

            # Replace non-deployed tasks in the plan by deployed ones
            #
            # The task-to-deployment association is handled by the network's
            # deployment groups (accessible through {Component#requirements})
            # as well as the default deployment group ({#default_deployment_group})
            #
            # @param [Boolean] validate if true, {#validate_deployed_networks}
            #   will run on the generated network
            # @return [Set] the set of tasks for which the deployer could
            #   not find a deployment
            def deploy(validate: true)
                debug "Deploying the system network"

                deployment_groups = propagate_deployment_groups

                debug do
                    debug "Deployment candidates"
                    log_nest(2) do
                        deployment_groups.each do |task, group|
                            candidates = group.
                                find_all_suitable_deployments_for(task)
                            log_pp :debug, task
                            log_nest(2) do
                                if candidates.empty?
                                    debug "no deployments"
                                else
                                    candidates.each do |deployment|
                                        log_pp :debug, deployment
                                    end
                                end
                            end
                        end
                    end
                    break
                end

                all_tasks = plan.find_local_tasks(TaskContext).to_a
                selected_deployments, missing_deployments =
                    select_deployments(all_tasks, deployment_groups)
                log_timepoint 'select_deployments'

                apply_selected_deployments(selected_deployments)
                log_timepoint 'apply_selected_deployments'

                if validate
                    validate_deployed_network(deployment_groups)
                    log_timepoint 'validate_deployed_network'
                end

                return missing_deployments
            end

            # @api private
            #
            # A DFS visitor that propagates the deployment group attribute in
            # the plan hierarchy
            class DeploymentGroupVisitor < RGL::DFSVisitor
                attr_reader :default_group
                attr_reader :deployment_groups

                attr_predicate :use_cow?

                def initialize(graph, default_group, use_cow: true)
                    super(graph)
                    @default_group = default_group
                    @deployment_groups = Hash.new
                    @use_cow = use_cow
                end

                def handle_start_vertex(root_task)
                    return if !root_task.kind_of?(Syskit::Component)
                    task_group = root_task.requirements.deployment_group
                    group =
                        if task_group.empty?
                            default_group
                        else task_group
                        end

                    deployment_groups[root_task] =
                        if use_cow?
                            [true, group]
                        else
                            [false, group.dup]
                        end
                end

                def self.update_deployment_groups(
                        deployment_groups, task, added_group, use_cow: true)
                    shared, existing_group = deployment_groups[task]
                    if existing_group
                        if existing_group.eql?(added_group)
                            return
                        elsif shared
                            existing_group = existing_group.dup
                        end
                        existing_group.use_group(added_group)
                        deployment_groups[task] = [false, existing_group]
                    elsif use_cow
                        deployment_groups[task] = [true, added_group]
                    else
                        deployment_groups[task] = [false, added_group.dup]
                    end
                end

                def propagate_deployment_group(parent_task, child_task)
                    if !parent_task.kind_of?(Syskit::Component)
                        if child_task.kind_of?(Syskit::Component) &&
                                !deployment_groups[child_task]
                            handle_start_vertex(child_task)
                        end
                        return
                    elsif !child_task.kind_of?(Syskit::Component)
                        return
                    end

                    child_group = child_task.requirements.deployment_group
                    if !child_group.empty?
                        deployment_groups[child_task] =
                            if use_cow?
                                [true, child_group]
                            else
                                [false, child_group.dup]
                            end
                    else
                        _, parent_group = deployment_groups[parent_task]
                        DeploymentGroupVisitor.update_deployment_groups(
                            deployment_groups, child_task, parent_group,
                            use_cow: use_cow?)
                    end
                end

                def handle_tree_edge(parent_task, child_task)
                    propagate_deployment_group(parent_task, child_task)
                end
                def handle_forward_edge(parent_task, child_task)
                    propagate_deployment_group(parent_task, child_task)
                end
            end

            # @api private
            #
            # Create a hash of task instances to the deployment group that
            # should be used for that instance
            def propagate_deployment_groups(use_cow: true)
                dependency_graph = plan.
                    task_relation_graph_for(Roby::TaskStructure::Dependency)

                all_groups = Hash.new
                dependency_graph.each_vertex do |task|
                    next unless dependency_graph.root?(task)

                    visitor = DeploymentGroupVisitor.new(
                        dependency_graph, default_deployment_group, use_cow: use_cow)
                    visitor.handle_start_vertex(task)
                    dependency_graph.depth_first_visit(task, visitor) {}

                    visitor.deployment_groups.each do |task, (_shared, task_group)|
                        DeploymentGroupVisitor.update_deployment_groups(
                            all_groups, task, task_group, use_cow: use_cow)
                    end
                end

                groups = Hash.new
                all_groups.each do |task, (_shared, task_group)|
                    groups[task] = task_group
                end

                # 'groups' here includes only the tasks that are in the
                # dependency graph. Make sure we add entries for the rest as
                # well
                plan.find_local_tasks(Syskit::Component).each do |task|
                    if !groups.has_key?(task)
                        task_group = task.requirements.deployment_group
                        groups[task] =
                            if task_group.empty?
                                default_deployment_group
                            else task_group
                            end
                    end
                end
                groups
            end

            # Finds the deployments suitable for a task in a given group
            #
            # If more than one deployment matches in the group, it calls
            # {#resolve_deployment_ambiguity} to try and pick one
            #
            # @param [Component] task
            # @param [Models::DeploymentGroup] deployment_groups
            # @return [nil,Deployment]
            def find_suitable_deployment_for(task, deployment_groups)
                candidates = deployment_groups[task].
                    find_all_suitable_deployments_for(task)

                return candidates.first if candidates.size <= 1

                debug do
                    "#{candidates.size} deployments available for #{task} "\
                    "(#{task.concrete_model}), trying to resolve"
                end
                selected = log_nest(2) do
                    resolve_deployment_ambiguity(candidates, task)
                end
                if selected
                    debug { "  selected #{selected}" }
                    return selected
                else
                    debug do
                        "  deployment of #{task} (#{task.concrete_model}) "\
                        "is ambiguous"
                    end
                    return
                end
            end

            # Find which deployments should be used for which tasks
            #
            # @param [[Component]] tasks the tasks to be deployed
            # @param [Component=>Models::DeploymentGroup] the association
            #   between a component and the group that should be used to
            #   deploy it
            # @return [(Component=>Deployment,[Component])] the association
            #   between components and the deployments that should be used
            #   for them, and the list of components without deployments
            def select_deployments(tasks, deployment_groups)
                used_deployments = Set.new
                missing_deployments = Set.new
                selected_deployments = Hash.new

                tasks.each do |task|
                    next if task.execution_agent
                    if !(selected = find_suitable_deployment_for(task, deployment_groups))
                        missing_deployments << task
                    elsif used_deployments.include?(selected)
                        debug do
                            machine, configured_deployment, task_name = *selected
                            "#{task} resolves to #{configured_deployment}.#{task_name} "\
                                "on #{machine} for its deployment, but it is already used"
                        end
                        missing_deployments << task
                    else
                        used_deployments << selected
                        selected_deployments[task] = selected
                    end
                end
                [selected_deployments, missing_deployments]
            end

            # Modify the plan to apply a deployment selection
            #
            # @param [Component=>Deployment] selected_deployments the
            #   component-to-deployment association
            # @return [void]
            def apply_selected_deployments(selected_deployments)
                deployment_tasks = Hash.new
                selected_deployments.each do |task, (configured_deployment, task_name)|
                    deployment_task = (deployment_tasks[[configured_deployment]] ||=
                            configured_deployment.new)

                    if Syskit.conf.permanent_deployments?
                        plan.add_permanent_task(deployment_task)
                    else
                        plan.add(deployment_task)
                    end
                    deployed_task = deployment_task.task(task_name)
                    debug { "deploying #{task} with #{task_name} of "\
                        "#{configured_deployment.short_name} (#{deployed_task})" }
                    # We MUST merge one-by-one here. Calling apply_merge_group
                    # on all the merges at once would NOT copy the connections
                    # that exist between the tasks of the "from" group to the
                    # "to" group, which is really not what we want
                    #
                    # Calling with all the mappings would be useful if what
                    # we wanted is replace a subnet of the plan by another
                    # subnet. This is not the goal here.
                    merge_solver.apply_merge_group(task => deployed_task)
                end
            end

            # Sanity checks to verify that the result of #deploy_system_network
            # is valid
            #
            # @raise [MissingDeployments] if some tasks could not be deployed
            def validate_deployed_network(deployment_groups)
                verify_all_tasks_deployed(deployment_groups)
            end

            # Verifies that all tasks in the plan are deployed
            #
            # @param [Component=>DeploymentGroup] deployment_groups which
            #   deployment groups has been used for which task. This is used
            #   to generate the error messages when needed.
            def verify_all_tasks_deployed(deployment_groups)
                not_deployed = plan.find_local_tasks(TaskContext).
                    not_finished.not_abstract.
                    find_all { |t| !t.execution_agent }

                if !not_deployed.empty?
                    tasks_with_candidates = Hash.new
                    not_deployed.each do |task|
                        candidates = deployment_groups[task].
                            find_all_suitable_deployments_for(task)
                        candidates = candidates.map do |configured_deployment, task_name|
                            existing = plan.find_local_tasks(task.model).
                                find_all { |t| t.orocos_name == task_name }
                            [configured_deployment, task_name, existing]
                        end

                        tasks_with_candidates[task] = candidates
                    end
                    raise MissingDeployments.new(tasks_with_candidates),
                        "there are tasks for which it exists no deployed equivalent: "\
                        "#{not_deployed.map { |m| "#{m}(#{m.orogen_model.name})" }}"
                end
            end

            # Try to resolve a set of deployment candidates for a given task
            #
            # @param [Array<(String,Model<Deployment>,String)>] candidates set
            #   of deployment candidates as
            #   (process_server_name,deployment_model,task_name) tuples
            # @param [Syskit::TaskContext] task the task context for which
            #   candidates are possible deployments
            # @return [(Model<Deployment>,String),nil] the resolved
            #   deployment, if finding a single best candidate was possible, or
            #   nil otherwise.
            def resolve_deployment_ambiguity(candidates, task)
                if task.orocos_name
                    debug { "#{task} requests orocos_name to be #{task.orocos_name}" }
                    resolved = candidates.
                        find { |_, task_name| task_name == task.orocos_name }
                    if !resolved
                        debug { "cannot find requested orocos name #{task.orocos_name}" }
                    end
                    return resolved
                end
                hints = task.deployment_hints
                debug { "#{task}.deployment_hints: #{hints.map(&:to_s).join(", ")}" }
                # Look to disambiguate using deployment hints
                resolved = candidates.find_all do |deployment_model, task_name|
                    task.deployment_hints.any? do |rx|
                        rx == deployment_model || rx === task_name
                    end
                end
                if resolved.size != 1
                    info do
                        info { "ambiguous deployment for #{task} (#{task.model})" }
                        candidates.each do |deployment_model, task_name|
                            info do
                                "  #{task_name} of #{deployment_model.short_name} "\
                                "on #{deployment_model.process_server_name}"
                            end
                        end
                        break
                    end
                    return
                end
                return resolved.first
            end
        end
    end
end
