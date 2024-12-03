# frozen_string_literal: true

module Syskit
    module Models
        module Deployment
            include Models::Base
            include MetaRuby::ModelAsClass
            include Models::OrogenBase

            # The options that should be passed when starting the underlying
            # Orocos process.
            #
            # @key_name option_name
            # @return [Hash<String,String>]
            inherited_attribute("default_run_option", "default_run_options", map: true) { {} }

            # The set of default name mappings for the instances of this
            # deployment model
            #
            # @key_name original_task_name
            # @return [Hash<String,String>]
            inherited_attribute("default_name_mapping", "default_name_mappings", map: true) { {} }

            # [Models::Deployment] Returns the parent model for this class, or
            # nil if it is the root model
            def supermodel
                if superclass.respond_to?(:register_submodel)
                    superclass
                end
            end

            # [Orocos::Generation::Deployment] the deployment model
            attr_accessor :orogen_model

            # Returns the name of this particular deployment instance
            def deployment_name
                orogen_model.name
            end

            def instanciate(plan, arguments = {})
                plan.add(task = new(arguments))
                task
            end

            # @api private
            #
            # Context object used to evaluate the block given to new_submodel
            class OroGenEvaluationContext < BasicObject
                attr_reader :task_name_to_syskit_model

                def initialize(task_m)
                    @task_m = task_m
                    @orogen_model = task_m.orogen_model
                    @task_name_to_syskit_model = {}
                end

                def task(name, model)
                    if model.respond_to?(:orogen_model)
                        deployed_task = @orogen_model.task(name, model.orogen_model)
                        @task_name_to_syskit_model[name] = model
                    else
                        deployed_task = @orogen_model.task(name, model)
                        @task_name_to_syskit_model[name] =
                            ::Syskit::TaskContext.model_for(deployed_task.task_model)
                    end

                    deployed_task
                end

                def respond_to_missing?(name, _private = false)
                    @orogen_model.respond_to?(name)
                end

                def method_missing(name, *args, **kw)
                    @orogen_model.send(name, *args, **kw)
                end
            end

            # Creates a new deployment model
            #
            # @option options [OroGen::Spec::Deployment] orogen_model the oroGen
            #   model for this deployment
            # @option options [String] name the model name, for anonymous model.
            #   It is usually not necessary to provide it.
            # @return [Deployment] the deployment class, as a subclass of
            #   Deployment
            def new_submodel(name: nil, orogen_model: nil, **options, &block)
                klass = super(name: name, **options) do
                    self.orogen_model = orogen_model ||
                        Models.create_orogen_deployment_model(name)

                    @task_name_to_syskit_model = {}
                    self.orogen_model.task_activities.each do |act|
                        @task_name_to_syskit_model[act.name] =
                            ::Syskit::TaskContext.model_for(act.task_model)
                    end

                    if block
                        ctxt = OroGenEvaluationContext.new(self)
                        ctxt.instance_eval(&block)
                        @task_name_to_syskit_model.merge!(ctxt.task_name_to_syskit_model)
                    end
                end
                klass.each_deployed_task_name do |name|
                    klass.default_name_mappings[name] = name
                end
                klass
            end

            # Creates a subclass of Deployment that represents the given
            # deployment
            #
            # @param [OroGen::Spec::Deployment] orogen_model the oroGen
            #   deployment model
            #
            # @option options [Boolean] register (false) if true, and if the
            #   deployment model has a name, the resulting syskit model is
            #   registered as a constant in the ::Deployments namespace. The
            #   constant's name is the camelized orogen model name.
            #
            # @return [Models::Deployment] the deployment model
            def define_from_orogen(orogen_model, register: false)
                model = new_submodel(orogen_model: orogen_model)
                if register && orogen_model.name
                    OroGen::Deployments.register_syskit_model(model)
                end
                model
            end

            # An array of Orocos::Generation::TaskDeployment instances that
            # represent the tasks available in this deployment. Associated plan
            # objects can be instanciated with #task
            def tasks
                orogen_model.task_activities
            end

            # Enumerate the unmapped names of the tasks deployed by self
            def each_deployed_task_name
                return enum_for(__method__) unless block_given?

                orogen_model.task_activities.each do |task|
                    yield(task.name)
                end
            end

            # @api private
            #
            # Resolve the Syskit task model for one of this deployment's tasks
            def resolve_syskit_model_for_deployed_task(deployed_task)
                task_name = deployed_task.name
                if (registered = @task_name_to_syskit_model[task_name])
                    return registered
                end

                # If this happens, it is most probably because the caller modified
                # the underlying orogen model directly. Warn about that
                Roby.warn_deprecated(
                    "Modifying the orogen model of a deployment is deprecated. Define " \
                    "the orogen model before the syskit model creation, or use " \
                    "Deployment.define_deployed_task"
                )

                @task_name_to_syskit_model[task_name] =
                    ::Syskit::TaskContext.model_for(deployed_task.task_model)
            end

            # Enumerate the tasks that are deployed in self
            #
            # @yieldparam [String] name the unmapped task name
            # @yieldparam [Models::TaskContext] model the deployed task model
            def each_deployed_task_model
                return enum_for(__method__) unless block_given?

                each_orogen_deployed_task_context_model do |deployed_task|
                    task_model = resolve_syskit_model_for_deployed_task(deployed_task)
                    yield(deployed_task.name, task_model)
                end
            end

            # Enumerates the deployed tasks this deployment contains
            #
            # @yieldparam [Orocos::Generation::DeployedTask] deployed_task
            # @return [void]
            def each_orogen_deployed_task_context_model(&block)
                orogen_model.task_activities.each(&block)
            end
        end
    end
end
