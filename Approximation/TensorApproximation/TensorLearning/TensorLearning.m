% Class TensorLearning: learning with tensor formats

% Copyright (c) 2020, Anthony Nouy, Erwan Grelier, Loic Giraldi
% 
% This file is part of ApproximationToolbox.
% 
% ApproximationToolbox is free software: you can redistribute it and/or modify
% it under the terms of the GNU Lesser General Public License as published by
% the Free Software Foundation, either version 3 of the License, or
% (at your option) any later version.
% 
% ApproximationToolbox is distributed in the hope that it will be useful,
% but WITHOUT ANY WARRANTY; without even the implied warranty of
% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
% GNU Lesser General Public License for more details.
% 
% You should have received a copy of the GNU Lesser General Public License
% along with ApproximationToolbox.  If not, see <https://www.gnu.org/licenses/>.

classdef TensorLearning < Learning
    
    properties
        % ORDER - Order of the tensor
        order
        % BASES - FunctionalBases
        bases
        % BASESEVAL - Cell of bases evaluations
        basesEval
        % ALGORITHM - Char specifying the choice of algorithm
        algorithm = 'standard'
        % INITIALIZATIONTYPE - Char specifying the type of initialization
        initializationType
        % INITIALGUESS - Initial guess for the learning algorithm
        initialGuess
        % TREEADAPTATION - Logical enabling or disabling the tree adaptation
        treeAdaptation = false
        % TREEADAPTATIONOPTIONS - Structure specifying the options for the tree adaptation
        treeAdaptationOptions = struct('tolerance',[],'maxIterations',100,'forceRankAdaptation',true)
        % RANKADAPTATION - Logical enabling or disabling the rank adaptation
        rankAdaptation = false
        % RANKADAPTATIONOPTIONS - Structure specifying the options for the rank adaptation
        rankAdaptationOptions = struct('maxIterations',10,'earlyStopping',false,'earlyStoppingFactor',10)
        % TOLERANCE - Structure specifying the options for the stopping criteria
        tolerance = struct('onError',1e-6,'onStagnation',1e-6)
        % LINEARMODELLEARNING - LinearModelLearning
        linearModelLearning
        % LINEARMODELLEARNINGPARAMETERS - Structure specifying the parameters for the linear model learning
        linearModelLearningParameters = struct('identicalForAllParameters',true)
        % ALTERNATINGMINIMIZATIONPARAMETERS - Structure specifying the options for the alternating minimization
        alternatingMinimizationParameters = struct('display',false,...
            'maxIterations',30,'stagnation',1e-6,'random',false)
        % BASESADAPTATIONPATH - Cell containing the adaptation paths
        basesAdaptationPath
        % TESTERROR - Logical enabling or disabling the computation of the test error
        testError = false
        % TESTERRORDATA - Cell containing the data required to compute the test error
        testErrorData
        % STOREITERATES - Logical enabling or disabling the storage of the iterates
        storeIterates = true
        % RANK - 1-by-1 or 1-by-order integer
        rank = 1
    end
    
    properties (Hidden)
        % NUMBEROFPARAMETERS - Integer
        numberOfParameters
        % EXPLORATIONSTRATEGY - 1-by-numberOfParameters integer: ordering for the optimization of each parameter
        explorationStrategy
        % ORTHONORMALITYWARNINGDISPLAY - Logical
        orthonormalityWarningDisplay = true
    end
    
    methods
        function s = TensorLearning(varargin)
            % TENSORLEARNING - Constructor for the TensorLearning class
            %
            % s = TENSORLEARNING(loss)
            % loss: LossFunction
            % s: TENSORLEARNING
            
            s@Learning(varargin{:});
            s.linearModelLearning = linearModel(Learning(s.lossFunction));
        end
        
        function [f,output] = solve(s,varargin)
            % SOLVE - Solver for the learning problem with tensor formats
            %
            % [f,output] = SOLVE(s,y,x)
            % s: TensorLearning
            % y: n-by-1 double
            % x: n-by-s.order double
            % f: FunctionalTensor
            % output: structure
            
            if s.orthonormalityWarningDisplay && (isempty(s.bases) || ...
                    (~isempty(s.bases) && ~all(cellfun(@(x) x.isOrthonormal,s.bases.bases))))
                s.orthonormalityWarningDisplay = false;
                warning('The implemented learning algorithms are designed for orthonormal bases. These algorithms work with non-orthonormal bases, but without some guarantees on their results.')
            end
            
            % If no FunctionalBases is provided, the test Error is not computed
            if s.testError && ~isa(s.bases,'FunctionalBases')
                s.testError = false;
            end
            
            if s.rankAdaptation
                if ~isfield(s.rankAdaptationOptions,'type')
                    [f,output] = solveAdaptation(s,varargin{:});
                elseif ischar(s.rankAdaptationOptions.type)
                    % Call the method corresponding to the asked rank adaptation option
                    str = lower(s.rankAdaptationOptions.type); str(1) = upper(str(1));
                    eval(['[f,output] = solve',str,'RankAdaptation(s,varargin{:});']);
                else
                    error('The rankAdaptationOptions property must be either empty or a string.')
                end
            elseif strcmpi(s.algorithm,'standard')
                [f,output] = solveStandard(s,varargin{:});
            else
                str = lower(s.algorithm); str(1) = upper(str(1));
                eval(['[f,output] = solve',str,'(s,varargin{:});']);
            end
        end
        
        function [f,output] = solveStandard(s,y,x)
            % SOLVESTANDARD - Solver for the learning problem with tensor formats using the standard algorithm (without adaptation)
            %
            % [f,output] = SOLVESTANDARD(s,y,x)
            % s: TensorLearning
            % y: n-by-1 double
            % x: n-by-s.order double
            % f: FunctionalTensor
            % output: structure
            
            % Bases evaluation
            if nargin>=3 && ~isempty(x)
                s.basesEval = eval(s.bases,x);
            end
            s.basesEval = cellfun(@full,s.basesEval,'uniformoutput',false);
            
            output.flag = 0;
            
            [s,f] = initialize(s,y); % Initialization
            f = FunctionalTensor(f,s.basesEval);
            
            % Replication of the LinearModelLearning objects
            if s.linearModelLearningParameters.identicalForAllParameters && length(s.linearModelLearning) == 1
                s.linearModelLearning = repmat({s.linearModelLearning},1,s.numberOfParameters);
            elseif length(s.linearModelLearning) ~= s.numberOfParameters
                error('Must provide numberOfParameters LinearModelLearning objects.')
            end
            
            % Working set paths
            if any(cellfun(@(x) x.basisAdaptation,s.linearModelLearning)) && isempty(s.basesAdaptationPath)
                s.basesAdaptationPath = adaptationPath(s.bases);
            end
            
            if s.alternatingMinimizationParameters.maxIterations == 0
                return
            end
            
            % Alternating minimization loop
            for k = 1:s.alternatingMinimizationParameters.maxIterations
                [s,f] = preProcessing(s,f); % Pre-processing
                f0 = f;
                
                if s.alternatingMinimizationParameters.random
                    alphaList = randomizeExplorationStrategy(s); % Randomize the exploration strategy
                else
                    alphaList = s.explorationStrategy;
                end
                
                for alpha = alphaList
                    [s,A,b,f] = prepareAlternatingMinimizationSystem(s,f,alpha,y);
                    [C, outputLML] = s.linearModelLearning{alpha}.solve(b,A);
                    
                    if isempty(C) || ~nnz(C) || ~all(isfinite(C)) || any(isnan(C))
                        warning('Empty, zero or NaN solution, returning to the previous iteration.')
                        output.flag = -2;
                        output.error = Inf;
                        break
                    end
                    
                    f = setParameter(s,f,alpha,C);
                end
                
%                 if k ~= s.alternatingMinimizationParameters.maxIterations && ...
%                         isa(s,'TreeBasedTensorWithMappedVariablesLearning')
%                     [s,f] = optimizeChangeOfVariables(s,f,y);
%                 end
                
                stagnation = stagnationCriterion(s,f,f0);
                output.stagnationIterations(k)=stagnation;
                
                if s.storeIterates
                    if isa(s.bases,'FunctionalBases')
                        output.iterates{k} = FunctionalTensor(f.tensor,s.bases);
                    else
                        output.iterates{k} = f;
                    end
                end
                
                if isfield(outputLML,'error')
                    output.error = outputLML.error;
                end
                
                if s.testError
                    output.testError = s.lossFunction.testError(FunctionalTensor(f.tensor,s.bases),s.testErrorData);
                    output.testErrorIterations(k) = output.testError;
                end
                
                if s.alternatingMinimizationParameters.display
                    fprintf('\tAlt. min. iteration %i: stagnation = %.2d',k,stagnation)
                    if isfield(output,'error')
                        fprintf(', error = %.2d',output.error)
                    end
                    if s.testError
                        fprintf(', test error = %.2d',output.testError);
                    end
                    fprintf('\n')
                end
                
                if (k>1) && stagnation < s.alternatingMinimizationParameters.stagnation
                    output.flag = 1;
                    break
                end
            end
            
            if isa(s.bases,'FunctionalBases')
                f = FunctionalTensor(f.tensor,s.bases);
            end
            output.iter = k;
            
            if s.display
                if s.alternatingMinimizationParameters.display
                    fprintf('\n')
                end
                finalDisplay(s,f);
                if isfield(output,'error')
                    fprintf(', CV error = %.2d',output.error)
                end
                if isfield(output,'testError')
                    fprintf(', test error = %.2d',output.testError)
                end
                fprintf('\n')
            end
        end
        
        function [f,output] = solveAdaptation(s,y,x)
            % SOLVEADAPTATION - Solver for the learning problem with tensor formats using the adaptive algorithm
            %
            % [f,output] = SOLVEADAPTATION(s,y,x)
            % s: TensorLearning
            % y: n-by-1 double
            % x: n-by-s.order double
            % f: FunctionalTensor
            % output: structure
            
            % Bases evaluation
            if nargin>=3 && ~isempty(x)
                s.basesEval = eval(s.bases,x);
            end
            
            slocal = localSolver(s);
            slocal.display = false;
            
            flag = 0;
            treeAdapt = false;
            
            f = [];
            errors = zeros(1,s.rankAdaptationOptions.maxIterations);
            testErrors = zeros(1,s.rankAdaptationOptions.maxIterations);
            iterates = cell(1,s.rankAdaptationOptions.maxIterations);
            
            newRank = slocal.rank;
            enrichedNodes = [];
            
            for i = 1:s.rankAdaptationOptions.maxIterations
                slocal.bases = s.bases;
                slocal.basesEval = s.basesEval;
                slocal.testErrorData = s.testErrorData;
                slocal.rank = newRank;
                
                fOld = f;
                [f,outputLocal] = slocal.solve(y);
                if isfield(outputLocal,'error')
                    errors(i)=outputLocal.error;
                    if isinf(errors(i))
                        disp('Infinite error, returning the previous iterate.')
                        f = fOld;
                        i = i - 1;
                        flag = -2;
                        break
                    end
                end
                
%                 if isa(slocal,'TreeBasedTensorWithMappedVariablesLearning')
%                     s.bases = f.bases;
%                     s.basesEval = s.bases.eval(x);
%                 end
                
                if s.testError
                    testErrors(i) = s.lossFunction.testError(FunctionalTensor(f.tensor,s.bases),s.testErrorData);
                end
                
                if s.rankAdaptationOptions.earlyStopping && ...
                        i > 1 && ((s.testError && (isnan(testErrors(i)) || s.rankAdaptationOptions.earlyStoppingFactor*min(testErrors(1:i-1)) < testErrors(i))) || ...
                        (isfield(outputLocal,'error') && ( isnan(errors(i)) || s.rankAdaptationOptions.earlyStoppingFactor*min(errors(1:i-1)) < errors(i))))
                    fprintf('Early stopping')
                    if isfield(outputLocal,'error')
                        fprintf(', error = %d',errors(i))
                    end
                    if s.testError
                        fprintf(', test error = %d',testErrors(i))
                    end
                    fprintf('\n\n')
                    i = i-1;
                    f = fOld;
                    flag = -1;
                    break
                end
                
                if s.display
                    if s.alternatingMinimizationParameters.display
                        fprintf('\n')
                    end
                    fprintf('\nRank adaptation, iteration %i:\n',i)
                    adaptationDisplay(s,f,enrichedNodes);
                    
                    fprintf('\tStorage complexity = %i\n',storage(f.tensor))
                    
                    if errors(i) ~= 0
                        fprintf('\tError      = %.2d\n',errors(i))
                    end
                    if  testErrors(i) ~= 0
                        fprintf('\tTest Error = %.2d\n',testErrors(i))
                    end
                    
                    if s.alternatingMinimizationParameters.display
                        fprintf('\n')
                    end
                end
                
                ok = false;
                if slocal.treeAdaptation && i>1 && ...
                        (~s.treeAdaptationOptions.forceRankAdaptation || ~treeAdapt)
                    Cold = storage(f.tensor);
                    [s,f,output] = adaptTree(s,f,errors(i),[],output,i);
                    ok = storage(f.tensor) < Cold;
                    if ok
                        if s.display
                            fprintf('\t\tStorage complexity before permutation = %i\n',Cold);
                            fprintf('\t\tStorage complexity after permutation  = %i\n',storage(f.tensor));
                        end
                        if s.testError
                            testErrors(i) = s.lossFunction.testError(FunctionalTensor(f.tensor,s.bases),s.testErrorData);
                            if s.display
                                fprintf('\t\tTest error after permutation = %.2d\n',testErrors(i));
                            end
                        end
                        if s.alternatingMinimizationParameters.display
                            fprintf('\n')
                        end
                    end
                end
                
                if s.storeIterates
                    if isa(s.bases,'FunctionalBases')
                        iterates{i} = FunctionalTensor(f.tensor,s.bases);
                    else
                        iterates{i} = f;
                    end
                end
                
                if i == s.rankAdaptationOptions.maxIterations
                    break
                end
                
                if (s.testError && isfield(outputLocal,'testError') && ...
                        testErrors(i) < s.tolerance.onError) || ...
                        (isfield(outputLocal,'error') && ...
                        errors(i) < s.tolerance.onError)
                    flag = 1;
                    break
                end
                
                if ~s.treeAdaptation || ~ok
                    if i>1 && ~treeAdapt && stagnationCriterion(s,FunctionalTensor(f.tensor,s.basesEval),FunctionalTensor(fOld.tensor,s.basesEval)) < s.tolerance.onStagnation
                        break
                    end
                    treeAdapt = false;
                    [f,newRank,enrichedNodes,tensorForInitialization] = newRankSelection(s,f,y);
                    output.enrichedNodesIterations{i} = enrichedNodes;
                    slocal = initialGuessNewRank(s,slocal,tensorForInitialization,y,newRank);
                else
                    treeAdapt = true;
                    enrichedNodes = [];
                    newRank = f.tensor.ranks;
                    slocal.initializationType = 'initialguess';
                    slocal.initialGuess = f.tensor;
                end
            end
            
            if isa(s.bases,'FunctionalBases')
                f = FunctionalTensor(f.tensor,s.bases);
            end
            
            if s.storeIterates
                output.iterates = iterates(1:i);
            end
            output.flag = flag;
            if isfield(outputLocal,'error')
                output.errorIterations = errors(1:i);
                output.error = errors(i);
            end
            if s.testError
                output.testErrorIterations = testErrors(1:i);
                output.testError = testErrors(i);
            end
        end
    end
    
    methods (Abstract)
        %% Standard solver methods
        
        % INITIALIZE - Initialization of the learning algorithm
        %
        % [s,f] = INITIALIZE(s,y)
        % s: TensorLearning
        % y: n-by-1 double
        % f: AlgebraicTensor
        [s,f] = initialize(s,y);
        
        % PREPROCESSING - Initialization of the alternating minimization algorithm
        %
        % [s,f] = PREPROCESSING(s,y)
        % s: TensorLearning
        % y: n-by-1 double
        % f: AlgebraicTensor
        [s,f] = preProcessing(s,f);
        
        % RANDOMIZEEXPLORATIONSTRATEGY - Randomization of the exploration strategy
        %
        % selmu = RANDOMIZEEXPLORATIONSTRATEGY(s)
        % s: TensorLearning
        % selmu: 1-by-s.numberOfParameters integer
        selmu = randomizeExplorationStrategy(s);
        
        % PREPAREALTERNATINGMINIMIZATIONSYSTEM - Preparation of the alternating minimization algorithm
        %
        % [s,A,b] = PREPAREALTERNATINGMINIMIZATIONSYSTEM(s,f,mu,y)
        % s: TensorLearning
        % f: FunctionalTensor
        % mu: 1-by-1 integer
        % y: n-by-1 double
        % A: n-by-numel(f.tensor.tensors{mu}) double
        % b: n-by-1 double
        [s,A,b] = prepareAlternatingMinimizationSystem(s,f,mu,y);
        
        % SETPARAMETER - Update of the parameter of the tensor
        %
        % f = SETPARAMETER(s,f,mu,a)
        % s: TensorLearning
        % f: FunctionalTensor
        % mu: 1-by-1 integer
        % a: numel(f.tensor.tensors{mu})-by-1 double
        f = setParameter(s,f,mu,a);
        
        % STAGNATIONCRITERION - Computation of the stagnation criterion
        %
        % stagnation = STAGNATIONCRITERION(s,f,f0)
        % Computes an indicator of the stagnation of the alternating minimization, using current and previous iterates f and f0
        % s: TensorLearning
        % f,f0: FunctionalTensor
        % stagnation: 1-by-1 double
        stagnation = stagnationCriterion(s,f,f0);
        
        % FINALDISPLAY - Display at the end of the computation
        %
        % FINALDISPLAY(s,f)
        % s: TensorLearning
        % f: FunctionalTensor
        finalDisplay(s,f);
        
        %% Rank adaptation solver methods
        
        % LOCALSOLVER - Extraction of the solver for the adaptive algorithm
        %
        % slocal = LOCALSOLVER(s)
        % s, slocal: TensorLearning
        slocal = localSolver(s);
        
        % NEWRANKSELECTION - Selection of a new rank in the adaptive algorithm
        %
        % [f,newRank,enrichedNodes,tensorForInitialization] = NEWRANKSELECTION(s,f,y,output)
        % s: TensorLearning
        % f: FunctionalTensor
        % y: n-by-1 double
        % output: cell
        % newRank: 1-by-s.numberOfParameters integer
        % enrichedNodes: 1-by-N integer, with N the number of enriched nodes
        % tensorForInitialization: AlgebraicTensor
        [f,newRank,enrichedNodes,tensorForInitialization] = newRankSelection(s,f,y,output);
        
        % INITIALGUESSNEWRANK - Computation of the initial guess with the new selected rank
        %
        % slocal = INITIALGUESSNEWRANK(s,slocal,f,y,newRank)
        % s, slocal: TensorLearning
        % f: FunctionalTensor
        % y: n-by-1 double
        % newRank: 1-by-s.numberOfParameters integer
        slocal = initialGuessNewRank(s,slocal,f,y,newRank);
        
        % ADAPTATIONDISPLAY - Display during the adaptation
        %
        % ADAPTATIONDISPLAY(s,f,enrichedNodes)
        % s: TensorLearning
        % f: FunctionalTensor
        % enrichedNodes: 1-by-N integer, with N the number of enriched nodes
        adaptationDisplay(s,f,enrichedNodes);
    end
    
end