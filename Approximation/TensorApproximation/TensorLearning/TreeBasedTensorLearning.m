% Class TreeBasedTensorLearning: learning with tree-based tensor formats
%
% References:
% - Grelier, E., Nouy, A., & Chevreuil, M. (2018). Learning with tree-based
% tensor formats. arXiv preprint arXiv:1811.04455
% - Grelier, E., Nouy, A., & Lebrun, R. (2019). Learning high-dimensional
% probability distributions using tree tensor networks. arXiv preprint
% arXiv:1912.07913.

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

classdef TreeBasedTensorLearning < TensorLearning
    
    properties
        % TREE - DimensionTree
        tree
        % ISACTIVENODE - 1-by-N logical specifying the active nodes
        isActiveNode
    end
    
    methods
        function s = TreeBasedTensorLearning(tree,isActiveNode,varargin)
            % TREEBASEDTENSORLEARNING - Constructor for the TreeBasedTensorLearning class
            %
            % s = TREEBASEDTENSORLEARNING(tree,activeNodes,loss)
            % tree: DimensionTree
            % isActiveNode: 1-by-tree.nbNodes logical
            % loss: LossFunction
            
            s@TensorLearning(varargin{:});
            
            s.tree = tree;
            s.isActiveNode = isActiveNode;
            s.order = numel(tree.dim2ind);
            s.numberOfParameters = nnz(isActiveNode);
            
            s.initializationType = 'canonical';
            s.rankAdaptationOptions.rankOneCorrection = true;
            s.rankAdaptationOptions.theta = 0.8;
            s.linearModelLearningParameters.basisAdaptationInternalNodes = false;
        end
        
        %% Standard solver methods
        function [s,f] = initialize(s)
            if isempty(s.tree)
                error('Must provide a DimensionTree object in property tree.')
            end
            
            if numel(s.rank) == 1 || numel(s.rank) == s.order
                r = zeros(1,s.tree.nbNodes);
                r(logical(s.isActiveNode)) = s.rank; r(s.tree.root) = 1;
                s.rank = r;
            end
            
            sz = cellfun(@(x) size(x,2),s.basesEval);
            switch lower(s.initializationType)
                case 'random'
                    f = TreeBasedTensor.randn(s.tree,s.rank,sz,s.isActiveNode);
                case 'ones'
                    f = TreeBasedTensor.ones(s.tree,s.rank,sz,s.isActiveNode);
                case 'initialguess'
                    f = s.initialGuess;
                case 'canonical'
                    f = canonicalInitialization(s,max(s.rank));
                    if ~all(f.ranks == s.rank)
                        tr = Truncator;
                        tr.tolerance = eps;
                        tr.maxRank = s.rank;
                        f = tr.truncate(f);
                    end
                otherwise
                    error('Wrong initialization type.')
            end
            if ~all(f.ranks == s.rank)
                f = enrichedEdgesToRanksRandom(f,s.rank);
            end
            
            % Exploration strategy of the tree by increasing level
            t = f.tree;
            explorationStrategy = zeros(1,s.numberOfParameters);
            ind = find(f.isActiveNode);
            i = 1;
            for lvl = 0:max(t.level)
                nodes = intersect(nodesWithLevel(t,lvl),ind);
                explorationStrategy(i:i+numel(nodes)-1) = nodes;
                i = i+numel(nodes);
            end
            s.explorationStrategy = explorationStrategy;
        end
        
        function [s,f] = preProcessing(s,f)
            if length(s.linearModelLearning) ~= s.tree.nbNodes
                c = cell(1,s.tree.nbNodes);
                c(s.isActiveNode) = s.linearModelLearning;
                s.linearModelLearning = c;
            end
        end
        
        function selmu = randomizeExplorationStrategy(s)
            selmu = zeros(1,s.numberOfParameters);
            for lvl = max(s.tree.level):-1:0
                [~,ind] = intersect(s.explorationStrategy,intersect(nodesWithLevel(s.tree,lvl),find(s.isActiveNode)));
                selmu(ind) = s.explorationStrategy(ind(randperm(length(ind))));
            end
        end
        
        function [s,A,b,f] = prepareAlternatingMinimizationSystem(s,f,mu)
            if s.linearModelLearning{mu}.basisAdaptation
                if ismember(mu,s.tree.internalNodes)
                    if s.linearModelLearningParameters.basisAdaptationInternalNodes
                        tr = Truncator('tolerance',eps,'MaxRank',max(f.tensor.ranks));
                        f.tensor = tr.hsvd(f.tensor);
                    else
                        s.linearModelLearning{mu}.basisAdaptation = false;
                    end
                end
                f.tensor = orthAtNode(f.tensor,mu);
                s.linearModelLearning{mu}.basisAdaptationPath = createBasisAdaptationPath(s,f.tensor.ranks,mu);
            else
                f.tensor = orthAtNode(f.tensor,mu);
            end
            g = parameterGradientEval(f,mu);
            A = reshape(g.data, g.sz(1),[]);
            
            if isa(s.lossFunction,'SquareLossFunction')
                b = s.trainingData{2};
            elseif isa(s.lossFunction,'DensityL2LossFunction')
                if ~iscell(s.trainingData)
                    b = [];
                elseif iscell(s.trainingData) && length(s.trainingData) == 2
                    y = s.trainingData{2};
                    if isa(y,'FunctionalTensor')
                        y = y.tensor;
                    end
                    y = orth(y);
                    if s.tree.isLeaf(mu)
                        a = y;
                        a.tensors(~s.tree.isLeaf) = cellfun(@(v,c) FullTensor(v.data.*c.data,v.order,v.sz),y.tensors(~s.tree.isLeaf),f.tensor.tensors(~s.tree.isLeaf),'UniformOutput',false);
                        I = setdiff(1:s.order,find(s.tree.dim2ind == mu));
                        C = cellfun(@(x) x.data, f.tensor.tensors(s.tree.dim2ind),'UniformOutput',false);
                        b = timesVector(a,C(I),I);
                        b = b.tensors{1}.data;
                    else
                        b = dot(f.tensor,y)/f.tensor.tensors{mu}.data;
                    end
                end
            end
        end
        
        function f = setParameter(s,f,mu,a)
            f.tensor.tensors{mu}.data = reshape(a,f.tensor.tensors{mu}.sz);
            f.tensor.tensors{mu}.isOrth = false;
        end
        
        function stagnation = stagnationCriterion(s,f,f0)
            stagnation = norm(f.tensor-f0.tensor)/norm(f0.tensor);
        end
        
        function finalDisplay(s,f)
            fprintf('Ranks = [ %s ]',num2str(f.tensor.ranks));
        end
        
        function f = canonicalInitialization(s,r)
            % CANONICALINITIALIZATION - Rank-r canonical initialization
            %
            % f = CANONICALINITIALIZATION(s,r)
            % s: TreeBasedTensorLearning
            % r: 1-by-1 integer
            % f: TreeBasedTensor
            
            C = CanonicalTensorLearning(s.order,s.lossFunction);
            if iscell(s.linearModelLearning)
                C.linearModelLearning = s.linearModelLearning{1};
            else
                C.linearModelLearning = s.linearModelLearning;
            end
            C.alternatingMinimizationParameters = s.alternatingMinimizationParameters;
            C.bases = s.bases;
            C.basesEval = s.basesEval;
            C.basesEvalTest = s.basesEvalTest;
            C.display = false;
            C.alternatingMinimizationParameters.display = false;
            C.initializationType = 'mean';
            C.rankAdaptation = true;
            C.rankAdaptationOptions.maxIterations = r;
            C.basesAdaptationPath = s.basesAdaptationPath;
            C.testError = s.testError;
            C.trainingData = s.trainingData;
            C.testData = s.testData;
            C.warnings = s.warnings;
            
            f = C.solve();
            f = treeBasedTensor(f.tensor,s.tree,s.isActiveNode);
        end
        
        function f = canonicalCorrection(s,f,r)
            % CANONICALCORRECTION - Rank-r canonical correction
            %
            % f = CANONICALCORRECTION(s,f,r)
            % s: TreeBasedTensorLearning
            % f: FunctionalTensor
            % r: 1-by-1 integer
            
            if isa(f,'FunctionalTensor')
                fx = timesMatrixEvalDiag(f.tensor,s.basesEval);
            elseif isempty(f)
                fx = 0;
            else
                error('Not implemented.')
            end
            
            if isa(s.lossFunction,'SquareLossFunction')
                R = s.trainingData{2} - fx;
            elseif isa(s.lossFunction,'DensityL2LossFunction')
                R = fx;
            end
            if ~iscell(s.trainingData)
                s.trainingData = {s.trainingData};
            end
            s.trainingData{2} = R;
            
            fadd = canonicalInitialization(s,r);
            if isa(fadd,'FunctionalTensor')
                fadd=fadd.tensor;
            end
            if ~isempty(f)
                f = f.tensor+fadd;
            else
                f = fadd;
            end
        end
        
        function f = rankOneCorrection(s,f)
            % RANKONECORRECTION - Rank one canonical correction
            %
            % f = RANKONECORRECTION(s,f)
            % s: TreeBasedTensorLearning
            % f: FunctionalTensor
            
            if isa(f,'FunctionalTensor')
                fx = timesMatrixEvalDiag(f.tensor,s.basesEval);
            elseif isempty(f)
                fx = 0;
            else
                error('Not implemented.')
            end
            
            if isa(s.lossFunction,'SquareLossFunction')
                R = s.trainingData{2} - fx;
            elseif isa(s.lossFunction,'DensityL2LossFunction')
                R = f;
            end
            
            slocal = s;
            slocal.rankAdaptation = false;
            slocal.treeAdaptation = false;
            slocal.rank = 1;
            slocal.display = false;
            slocal.alternatingMinimizationParameters.display = false;
            slocal.initializationType = 'ones';
            slocal.alternatingMinimizationParameters.maxIterations = 1;
            
            if ~iscell(slocal.trainingData)
                slocal.trainingData = {slocal.trainingData};
            end
            slocal.trainingData{2} = R;
            
            fadd = slocal.solve();
            
            if isa(fadd,'FunctionalTensor')
                fadd = fadd.tensor;
            end
            if ~isempty(f)
                f = f.tensor+fadd;
            else
                f = fadd;
            end
        end
        
        function p = createBasisAdaptationPath(s,r,alpha)
            % CREATEBASISADAPTATIONPATH - Creation of the basis adaptation path
            %
            % p = CREATEBASISADAPTATIONPATH(s,r,alpha)
            % s: TreeBasedTensorLearning
            % r: 1-by-s.numberOfParameters integer
            % alpha: 1-by-1 integer
            % p: logical matrix
            
            t = s.tree;
            if t.isLeaf(alpha)
                palpha = s.basesAdaptationPath{t.dim2ind == alpha};
                r = r(alpha);
                p = permute(palpha,[3,1,4,2]);
                p = repmat(p,[1,1,r,2]);
                p = reshape(p,[size(p,2)*r,size(p,4)]);
            else
                if s.linearModelLearningParameters.basisAdaptationInternalNodes
                    error('Basis adaptation for internal nodes is not implemented.')
                else
                    ch = nonzeros(t.children(:,alpha));
                    if all(~s.isActiveNode(ch))
                        [~,J] = find(t.dim2ind == ch);
                        palpha = s.basesAdaptationPath(J);
                        r = r(alpha);
                        p = permute(palpha{1},[3,1,4,2]);
                        p = repmat(p,[1,1,r,2]);
                        p = reshape(p,[size(p,2)*r,size(p,4)]);
                        for i = 2:length(palpha)
                            p = kron(p,palpha{i});
                        end
                    else
                        cha = ch(s.isActiveNode(ch));
                        chna = setdiff(ch,cha);
                        [~,J] = find(t.dim2ind == chna);
                        szna = cellfun(@(x) size(x,1),s.basesAdaptationPath(J));
                        p = true(prod([r([alpha ; cha]), szna(:).']),1); % No working set
                    end
                end
            end
        end
        
        %% Rank adaptation solver methods
        function slocal = localSolver(s)
            slocal = s;
            slocal.rankAdaptation = false;
            slocal.storeIterates = false;
            slocal.testError = false;
            
            if any(~s.isActiveNode) && s.treeAdaptation
                warning('Tree adaptation is not compatible with non active nodes, disabling it.')
                slocal.treeAdaptation = false;
            end
        end
        
        function [f, newRank, enrichedNodes, tensorForSelection] = newRankSelection(s,f)
            if s.rankAdaptationOptions.rankOneCorrection
                slocal = s;
                ranksAdd = ones(1,f.tensor.tree.nbNodes); ranksAdd(f.tensor.tree.root) = 0;
                slocal.rank = makeRanksAdmissible(f.tensor,f.tensor.ranks + ranksAdd);
                slocal.initializationType = 'InitialGuess';
                tr = Truncator('tolerance',0,'maxRank',slocal.rank);
                slocal.initialGuess = tr.truncate(rankOneCorrection(s,f));
                slocal.alternatingMinimizationParameters.maxIterations = 10;
                slocal.rankAdaptation = false;
                slocal.display = false;
                slocal.alternatingMinimizationParameters.display = false;
                tensorForSelection = slocal.solve();
                tensorForSelection = tensorForSelection.tensor;
            else
                tensorForSelection = f.tensor;
            end
            
            sv = singularValues(tensorForSelection);
            
            % Remove from the rank adaptation candidates: the inactive
            % nodes, the root, the leaf nodes with a rank equal to the
            % dimension of the basis associated to it, and the nodes for
            % which the smallest singular value is almost zero
            sv(~f.tensor.isActiveNode) = {NaN}; sv{f.tensor.tree.root} = NaN;
            dim2ind = intersect(f.tensor.tree.dim2ind,f.tensor.activeNodes);
            sv(dim2ind(~cellfun(@(x) range(x.sz), f.tensor.tensors(dim2ind)))) = {NaN};
            sv(slocal.rank ~= tensorForSelection.ranks) = {NaN};
            
            svmin = cellfun(@min,sv(1:end));
            svmin(svmin/norm(tensorForSelection) < eps) = NaN;
            
            % Removing nodes that cannot be enriched because their rank
            % is equal to the product of the ranks of their children,
            % and their children cannot be enriched themselves
            t = tensorForSelection.tree;
            r = f.tensor.ranks;
            desc = setdiff(1:t.nbNodes,find(t.isLeaf));
            cannotBeIncreased = false(1,t.nbNodes);
            cannotBeIncreased(t.root) = true;
            cannotBeIncreased(t.isLeaf) = isnan(svmin(t.isLeaf));
            for lvl = max(t.level)-1:-1:1
                nodLvl = intersect(nodesWithLevel(t,lvl),desc);
                for nod = nodLvl
                    ch = nonzeros(t.children(:,nod));
                    if all(cannotBeIncreased(ch)) && r(nod) == prod(r(ch))
                        cannotBeIncreased(nod) = true;
                    end
                end
            end
            cannotBeIncreasedNodes = t.nodesIndices(cannotBeIncreased);
            for lvl = 1:max(t.level)-1
                nodLvl = setdiff(nodesWithLevel(t,lvl), cannotBeIncreasedNodes);
                for nod = nodLvl
                    pa = t.parent(nod);
                    ind = setdiff(nonzeros(t.children(:,pa)), nod);
                    ind = [pa, ind(:).'];
                    if all(cannotBeIncreased(ind)) && ...
                            r(nod) == prod(r(ind))
                        cannotBeIncreased(nod) = true;
                    end
                end
            end
            svmin(cannotBeIncreased) = NaN;
            theta = s.rankAdaptationOptions.theta*max(svmin);
            
            enrichedNodes = find(svmin >= theta);
            newRank = f.tensor.ranks;
            newRank(enrichedNodes) = newRank(enrichedNodes) + 1;
            
            if ~isAdmissibleRank(f.tensor,newRank)
                % Add to the already enriched nodes nodes one by one in
                % decreasing order of singular value until the rank is
                % admissible
                enrichedNodesTheta = enrichedNodes;
                rTheta = newRank;
                svmin(enrichedNodesTheta) = NaN;
                svminSorted = uniquetol2(svmin,1e-2);
                svminSorted = flip(svminSorted);
                svminSorted(isnan(svminSorted)) = [];
                
                for i = 1:length(svminSorted)
                    newRank = rTheta;
                    ind = svmin >= svminSorted(i);
                    newRank(ind) = newRank(ind) + 1;
                    if isAdmissibleRank(f.tensor,newRank)
                        enrichedNodes = [enrichedNodesTheta, find(ind)];
                        break
                    end
                end
                if ~isAdmissibleRank(f.tensor,newRank)
                    newRank = f.tensor.ranks;
                    enrichedNodes = [];
                end
            end
        end
        
        function slocal = initialGuessNewRank(s,slocal,f,newRank)
            slocal.initializationType = 'initialguess';
            if ~all(f.ranks == newRank)
                tr = Truncator;
                tr.tolerance = 0;
                tr.maxRank = newRank;
                slocal.initialGuess = tr.truncate(f);
            else
                slocal.initialGuess = f;
            end
        end
        
        function adaptationDisplay(s,f,enrichedNodes)
            fprintf('\tEnriched nodes: [ %s ]\n\tRanks = [ %s]\n',num2str(enrichedNodes(:).'),num2str(f.tensor.ranks));
        end
        
        function [s,f,output] = adaptTree(s,f,looError,testError,output,varargin)
            % ADAPTTREE - Tree adaptation algorithm
            %
            % [s,f,output] = ADAPTTREE(s,f,error,testError,output)
            % s: TreeBasedTensorLearning
            % f: FunctionalTensor
            % error, testError: 1-by-1 double
            % output: struct
            
            if ~s.treeAdaptation
                return
            end
            
            if ~isempty(s.treeAdaptationOptions.tolerance)
                adaptTreeError = s.treeAdaptationOptions.tolerance;
            elseif strcmpi(s.lossFunction.errorType,'relative')
                if isempty(testError) || testError == 0
                    adaptTreeError = looError;
                elseif isempty(looError) && testError ~= 0
                    adaptTreeError = testError;
                end
            else
                warning('Must provide a tolerance for the tree adaptation in the treeAdaptationOptions property. Disabling tree adaptation.')
                s.treeAdaptation = false;
                return
            end
            
            fPerm = optimizeDimensionTree(f.tensor,adaptTreeError,s.treeAdaptationOptions.maxIterations);
            if storage(fPerm) < storage(f.tensor)
                f.tensor = fPerm;
                s.tree = f.tensor.tree;
                s.isActiveNode = f.tensor.isActiveNode;
                output.adaptedTree = true;
                if s.display
                    fprintf('\tTree adaptation:\n\t\tRanks after permutation = [ %s ]\n',num2str(f.tensor.ranks))
                end
            else
                output.adaptedTree = false;
            end
        end
        
    end
    
    methods (Static)
        function s = TensorTrain(d,varargin)
            % TENSORTRAIN - Call of the constructor of the class TreeBasedTensorLearning, with a tree and active nodes corresponding to the Tensor-Train format in dimension d
            %
            % s = TENSORTRAIN(d,loss)
            % d: 1-by-1 integer
            % loss: LossFunction
            %
            % See also TREEBASEDTENSORLEARNING
            
            tree = DimensionTree.linear(d);
            isActiveNode = true(1,tree.nbNodes);
            isActiveNode(tree.dim2ind(2:end)) = false;
            s = TreeBasedTensorLearning(tree,isActiveNode,varargin{:});
        end
        
        function s = TensorTrainTucker(d,varargin)
            % TENSORTRAINTUCKER - Call of the constructor of the class TreeBasedTensorLearning, with a tree and active nodes corresponding to the Tensor-Train Tucker format in dimension d
            %
            % s = TENSORTRAINTUCKER(d,loss)
            % d: 1-by-1 integer
            % loss: LossFunction
            %
            % See also TREEBASEDTENSORLEARNING
            
            tree = DimensionTree.linear(d);
            isActiveNode = true(1,tree.nbNodes);
            s = TreeBasedTensorLearning(tree,isActiveNode,varargin{:});
        end
    end
end

function f = enrichedEdgesToRanksRandom(f,newRank)
% ENRICHEDEDGESTORANKSRANSOM - Enrichment of the ranks of specified edges of the tensor f using random additions for each child / parent couple of the enriched edges
% f = ENRICHEDEDGESTORANKSRANSOM(f,newRank)
% f: TreeBasedTensor
% newRank: 1-by-s.numberOfParameters integer

f.isOrth = false;
t = f.tree;
enrichedDims = find(newRank>f.ranks);

for l = 1:max(t.level)
    nodLvl = intersect(nodesWithLevel(t,l),enrichedDims);
    for alpha = nodLvl
        gamma = t.parent(alpha);
        r = newRank(alpha)-f.ranks(alpha);
        
        A = reshape(f.tensors{alpha}.data,[],f.ranks(alpha));
        A(:,end+1:end+r) = repmat(A(:,end),1,r).*(1+randn(size(A,1),r));
        A(:,end-r+1:end) = A(:,end-r+1:end) ./ sqrt(sum(A(:,end-r+1:end).^2,1));
        f.tensors{alpha}.sz(end) = f.tensors{alpha}.sz(end)+r;
        f.tensors{alpha}.data = reshape(A,f.tensors{alpha}.sz);
        
        ch = f.tree.childNumber(alpha);
        ind = 1:f.tensors{gamma}.order;
        ind(ch) = [];
        ind = [ind , ch];
        A = permute(f.tensors{gamma}.data,ind);
        A = reshape(A,[],f.ranks(alpha));
        A(:,end+1:end+r) = repmat(A(:,end),1,r).*(1+randn(size(A,1),r));
        A(:,end-r+1:end) = A(:,end-r+1:end) ./ sqrt(sum(A(:,end-r+1:end).^2,1));
        f.tensors{gamma}.sz(ch) = f.tensors{gamma}.sz(ch)+r;
        A = reshape(A,f.tensors{gamma}.sz(ind));
        f.tensors{gamma}.data = ipermute(A,ind);
        
        f = updateProperties(f);
    end
end
end

function f = enrichedEdgesToRanksCanonical(s,f,newRank)
% ENRICHEDEDGEDTORANKSCANONICAL - Enrichment of the ranks of specified edges of the tensor f using canonical tensor approximations for each child / parent couple of the enriched edges
%
% f = ENRICHEDEDGEDTORANKSCANONICAL(s,f,newRank)
% s: TreeBasedTensorLearning
% f: TreeBasedTensor
% newRank: 1-by-s.numberOfParameters integer


if s.linearModelLearning.basisAdaptation && isempty(s.basesAdaptationPath)
    if ismethod(s.bases, 'adaptationPath')
        s.basesAdaptationPath = adaptationPath(s.bases);
    else
        warning('Cannot perform basis adaptation, disabling it.')
        s.linearModelLearning = cellfun(@(x) setfield(x, 'basisAdaptation', false), ...
            s.linearModelLearning, 'UniformOutput', false);
    end
end
H = s.basesEval;

t = f.tree;
enrichedDims = find(newRank>f.ranks);

for l = 1:max(t.level)
    nodLvl = intersect(nodesWithLevel(t,l),enrichedDims);
    for alpha = nodLvl
        gamma = t.parent(alpha);
        
        f = orthAtNode(f,gamma);
        
        fH = timesMatrix(f,H);
        v = evalDiagBelow(fH);
        w = evalDiagAbove(fH,v);
        
        addedRank = newRank(alpha)-f.ranks(alpha);
        
        chNod = nonzeros(t.children(:,alpha));
        aChNod = intersect(chNod,f.activeNodes);
        naChNod = chNod; naChNod(f.isActiveNode(naChNod)) = [];
        if t.isLeaf(alpha)
            Halpha = FullTensor(s.basesEval{f.tree.dim2ind == alpha});
            if s.linearModelLearning.basisAdaptation
                adaptationPathAlpha = s.basesAdaptationPath{f.tree.dim2ind == alpha};
            end
        else
            if ~isempty(aChNod)
                Halpha = v{aChNod(1)};
                if s.linearModelLearning.basisAdaptation
                    adaptationPathAlpha = ones(v{aChNod(1)}.sz(2),1);
                end
                for i = 2:length(aChNod)
                    Halpha = outerProductEvalDiag(Halpha,v{aChNod(i)},1,1);
                    if s.linearModelLearning.basisAdaptation
                        adaptationPathAlpha = kron(adaptationPathAlpha, ones(v{aChNod(i)}.sz(2),1));
                    end
                end
            end
            if ~isempty(naChNod)
                Ana = FullTensor(s.basesEval{t.dim2ind == naChNod(1)});
                if s.linearModelLearning.basisAdaptation
                    adaptationPathAlphaNa = s.basesAdaptationPath{f.tree.dim2ind == naChNod(1)};
                end
                for i = 2:length(naChNod)
                    Ana = outerProductEvalDiag(Ana,FullTensor(s.basesEval{t.dim2ind == naChNod(i)}),1,1);
                    if s.linearModelLearning.basisAdaptation
                        adaptationPathAlphaNa = kron(adaptationPathAlphaNa,s.basesAdaptationPath{f.tree.dim2ind == naChNod(i)});
                    end
                end
                if ~isempty(aChNod)
                    Halpha = outerProductEvalDiag(Halpha,Ana,1,1);
                    if s.linearModelLearning.basisAdaptation
                        adaptationPathAlpha = kron(adaptationPathAlpha,adaptationPathAlphaNa);
                    end
                else
                    Halpha = Ana;
                    if s.linearModelLearning.basisAdaptation
                        adaptationPathAlpha = adaptationPathAlphaNa;
                    end
                end
            end
        end
        rAlpha = Halpha.sz(2:end);
        Halpha = Halpha.data(:,:);
        
        chNod = setdiff(nonzeros(t.children(:,gamma)),alpha);
        aChNod = intersect(chNod,f.activeNodes);
        naChNod = chNod; naChNod(f.isActiveNode(naChNod)) = [];
        if ~isempty(aChNod)
            Hgamma = v{aChNod(1)};
            if s.linearModelLearning.basisAdaptation
                adaptationPathGamma = ones(v{aChNod(1)}.sz(2),1);
            end
            for i = 2:length(aChNod)
                Hgamma = outerProductEvalDiag(Hgamma,v{aChNod(i)},1,1);
                if s.linearModelLearning.basisAdaptation
                    adaptationPathGamma = kron(adaptationPathGamma, ones(v{aChNod(i)}.sz(2),1));
                end
            end
        end
        if ~isempty(naChNod)
            Ana = FullTensor(s.basesEval{t.dim2ind == naChNod(1)});
            if s.linearModelLearning.basisAdaptation
                adaptationPathGammaNa = s.basesAdaptationPath{f.tree.dim2ind == naChNod(1)};
            end
            for i = 2:length(naChNod)
                Ana = outerProductEvalDiag(Ana,FullTensor(s.basesEval{t.dim2ind == naChNod(i)}),1,1);
                if s.linearModelLearning.basisAdaptation
                    adaptationPathGammaNa = kron(adaptationPathGammaNa,s.basesAdaptationPath{f.tree.dim2ind == naChNod(i)});
                end
            end
            if ~isempty(aChNod)
                Hgamma = outerProductEvalDiag(Hgamma,Ana,1,1);
                if s.linearModelLearning.basisAdaptation
                    adaptationPathGamma = kron(adaptationPathGamma,adaptationPathGammaNa);
                end
            else
                Hgamma = Ana;
                if s.linearModelLearning.basisAdaptation
                    adaptationPathGamma = adaptationPathGammaNa;
                end
            end
        end
        
        if gamma == t.root
            sz = 1;
        else
            Hgamma = outerProductEvalDiag(Hgamma,w{gamma},1,1);
            sz = w{gamma}.sz(2);
        end
        
        if s.linearModelLearning.basisAdaptation
            adaptationPathGamma = kron(adaptationPathGamma,ones(sz,1));
        end
        
        rGamma = Hgamma.sz(2:end);
        Hgamma = Hgamma.data(:,:);
        
        fx = timesMatrixEvalDiag(f,s.basesEval);
        if isa(s.lossFunction,'SquareLossFunction')
            R = s.trainingData{2} - fx;
        elseif isa(s.lossFunction,'DensityL2LossFunction')
            R = fx;
        end
        if ~iscell(s.trainingData)
            trainingData = {s.trainingData};
        end
        trainingData{2} = R;
        
        C = CanonicalTensorLearning(2,s.lossFunction);
        C.trainingData = trainingData;
        if iscell(s.linearModelLearning)
            C.linearModelLearning = s.linearModelLearning{1};
        else
            C.linearModelLearning = s.linearModelLearning;
        end
        C.alternatingMinimizationParameters = s.alternatingMinimizationParameters;
        C.basesEval = {Halpha;Hgamma};
        C.display = false;
        C.tolerance.onStagnation = eps;
        C.alternatingMinimizationParameters.display = false;
        C.algorithm = 'greedy';
        C.initializationType = 'mean';
        if C.linearModelLearning.basisAdaptation
            C.basesAdaptationPath = ...
                {adaptationPathAlpha,...
                adaptationPathGamma};
        end
        C.rank = addedRank;
        C.warnings = structfun(@(x) false, s.warnings, 'UniformOutput', false);
        a = C.solve();
        r = size(a.space.spaces{1},2);
        
        ind = size(f.tensors{alpha}); ind(end) = r;
        alphaCore = reshape(a.space.spaces{1}, ind);
        alphaCore = FullTensor(alphaCore,length(rAlpha)+1,ind);
        
        ind = size(f.tensors{gamma}); ind(t.childNumber(alpha)) = r;
        gammaCore = reshape(a.space.spaces{2}*diag(a.core.data),ind);
        gammaCore = FullTensor(gammaCore,length(rGamma)+1,ind);
        
        f.tensors{alpha} = cat(f.tensors{alpha},alphaCore,f.tensors{alpha}.order);
        f.tensors{gamma} = cat(f.tensors{gamma},gammaCore,t.childNumber(alpha));
        f = updateProperties(f);
    end
end

f = orth(f);
end

function [r,d] = makeRanksAdmissible(f,r)
% MAKERANKSADMISSIBLE - Adjustment of the ranks to make the associated tree-based tensor f rank-admissible, by enriching new edges associated to nodes in d until all the rank admissibility conditions are met
%
% [r,d] = MAKERANKSADMISSIBLE(f,r)
% f: TreeBasedTensor
% r: 1-by-s.numberOfParameters integer
% d: 1-by-N integer, with N the number of nodes whose rank has been increased

% Do not increase the ranks of leaf nodes with rank equal to the dimension of the approximation space
I = f.activeNodes;
ind = f.tree.isLeaf(I) & r(I) > cellfun(@(x) x.sz(1), f.tensors(I));
r(I(ind)) = cellfun(@(x) x.sz(1), f.tensors(I(ind)));
r(~f.isActiveNode) = 0;

delta = r - f.ranks;
if isAdmissibleRank(f,f.ranks+delta)
    r = f.ranks + delta;
    d = find(delta);
    return
end

for i = 1:nnz(delta)
    pos = nchoosek(1:nnz(delta),i);
    pos = pos(randperm(size(pos,1)),:);
    for j = 1:size(pos,1)
        ind = find(delta);
        deltaLoc = delta;
        deltaLoc(ind(pos(j,:))) = 0;
        if isAdmissibleRank(f,f.ranks+deltaLoc)
            r = f.ranks + deltaLoc;
            d = find(deltaLoc);
            return
        end
    end
end

warning('Cannot find a representation with admissible ranks, returning previous ranks.')
r = f.ranks;
d = [];
end

function b = uniquetol2(a,tol)
% UNIQUETOL2 - Unique values within tolerance, with sorted output
%
% Two values a and b are within tolerance if abs(b-a)/b <= tol.
%
% b = UNIQUETOL2(a,tol)
% a: N-by-1 or 1-by-N double
% b: 1-by-M double, with M the number of unique terms in a within tolerance tol
% tol: 1-by-1 double
%
% See also UNIQUETOL

a = sort(a);
b = a(1);

for i = 2:length(a)
    if abs(b(end)-a(i))/b(end) > tol
        b = [b, a(i)];
    end
end
end