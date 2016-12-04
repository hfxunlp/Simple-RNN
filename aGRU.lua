--[[
	The GNU GENERAL PUBLIC LICENSE Version 3

	Copyright (c) 2016 Hongfei Xu

	This scripts implement a standard GRU:

	z[t] = σ(W[x->z]x[t] + W[s->z]s[t−1] + b[1->z])            (1)
	r[t] = σ(W[x->r]x[t] + W[s->r]s[t−1] + b[1->r])            (2)
	h[t] = tanh(W[x->h]x[t] + W[hr->c](s[t−1]r[t]) + b[1->h])  (3)
	s[t] = (1-z[t])h[t] + z[t]s[t-1]                           (4)

	Version 0.0.1

]]

local aGRU, parent = torch.class('nn.aGRU', 'nn.Container')

-- generate a module
function aGRU:__init(inputSize, outputSize, maskZero, remember)

	parent.__init(self)

	-- set wether mask zero
	self.maskzero = maskZero

	-- set wether remember the cell and output between sequence
	-- unless you really need, this was not advised
	-- if you use this,
	-- you need to have the same batchsize until you call forget,
	-- for the last time step,
	-- at least it must be little then the previous step
	self.rememberState = remember

	-- prepare should be only debug use consider of efficient
	self:prepare()

	-- asign the default method
	-- you can not asign the function,
	-- if you do, the function was saved
	-- so use inner call
	--self:_asign(seqData)

	-- forget gate start index
	-- also was used in updateOutput to prepare init cell and output,
	-- because it is outputSize + 1, take care of this
	self.fgstartid = outputSize + 1

	-- prepare to build the modules
	self.inputSize, self.outputSize = inputSize, outputSize

	self.narrowDim = 1

	self:reset()

end

-- fit torch standard,
-- calc an output for an input,
-- faster while you just specify which function to use
function aGRU:updateOutput(input)

	if torch.type(input) == 'table' then
		self.tablesequence = true
		self:_table_clearState()
		return self:_seq_updateOutput(input)
	else
		self.tablesequence = nil
		self:_tensor_clearState(input)
		return self:_tseq_updateOutput(input)
	end

end

-- fit torch standard,
-- backward,
-- faster while you just specify which function to use
function aGRU:backward(input, gradOutput, scale)

	if torch.type(input) == 'table' then
		return self:_seq_backward(input, gradOutput, scale)
	else
		return self:_tseq_backward(input, gradOutput, scale)
	end

end

-- fit torch rnn standard,
-- clear the cache used
function aGRU:clearState()

	if self.tablesequence then
		self:_table_clearState()
	else
		self:_tensor_clearState()
	end

	--[[for _, module in ipairs(self.modules) do
		module:clearState()
	end]]

end

-- asign default method
--[[function aGRU:_asign(seqd)

	if seqd then
		self.updateOutput = self._tseq_updateOutput
		self.backward = self._tseq_backward
		self._forget = self._tensor_forget
	else
		self.updateOutput = self._seq_updateOutput
		self.backward = self._seq_backward
		self._forget = self._table_forget
	end
	self.updateGradInput = self._seq_updateGradInput

end]]

-- updateOutput called by forward,
-- It input a time step's input and produce an output
function aGRU:_step_updateOutput(input)

	-- ensure cell and output are ready for the first step
	if not self.cell then
		-- set batch size and prepare the cell and output
		local _nIdim = input:nDimension()
		if _nIdim>1 then
			self.batchsize = input:size(1)

			if self.rememberState and self.lastCell then
				if self.lastCell:size(1) == self.batchsize then
					self.cell0 = self.lastCell
					self.output0 = self.lastOutput
				else
					self.cell0 = self.lastCell:narrow(1, 1, self.batchsize)
					self.output0 = self.lastOutput:narrow(1, 1, self.batchsize)
				end
			else
				self.cell0 = self.sbm.bias:narrow(1, 1, self.outputSize)
				self.cell0 = self.cell0:reshape(1,self.outputSize):expand(self.batchsize, self.outputSize)
				self.output0 = self.sbm.bias:narrow(1, self.fgstartid, self.outputSize)
				self.output0 = self.output0:reshape(1,self.outputSize):expand(self.batchsize, self.outputSize)
			end

			-- narrow dimension
			self.narrowDim = _nIdim
		else
			self.batchsize = nil

			if self.rememberState and self.lastCell then
				self.cell0 = self.lastCell
				self.output0 = self.lastOutput
			else
				self.cell0 = self.sbm.bias:narrow(1, 1, self.outputSize)
				self.output0 = self.sbm.bias:narrow(1, self.fgstartid, self.outputSize)
			end

			-- narrow dimension
			self.narrowDim = 1
		end
		self.cell = self.cell0
		self.output = self.output0
	end

	-- compute input gate and forget gate
	local _ifgo = self.ifgate:forward({input, self.output, self.cell})

	-- get input gate and forget gate
	local _igo = _ifgo:narrow(self.narrowDim, 1, self.outputSize)
	local _fgo = _ifgo:narrow(self.narrowDim, self.fgstartid, self.outputSize)

	-- compute update
	local _ho = self.hmod:forward({input, self.output})

	-- get new value of the cell
	self.cell = torch.add(torch.cmul(_fgo, self.cell),torch.cmul(_igo,_zo))

	-- compute output gate with the new cell,
	-- this is the standard lstm,
	-- otherwise it can be computed with input gate and forget gate
	local _ogo = self.ogate:forward({input, self.output, self.cell})

	-- compute the final output for this input
	local _otanh = torch.tanh(self.cell)
	self.output = torch.cmul(_ogo, _otanh)

	-- if training, remember what should remember
	if self.train then
		table.insert(self._cell, self.cell)
		table.insert(self._output, self.output)
		table.insert(self.otanh, _otanh)
		table.insert(self.ofgate, _fgo)
		table.insert(self.ougate, _ho)
	end

	-- return the output for this input
	return self.output

end

-- updateOutput for tensor input,
-- input tensor is expected to be seqlen * batchsize * vecsize
function aGRU:_tseq_updateOutput(input)

	self.gradInput:resize(0)

	-- get input and output size
	local iSize = input:size()
	local oSize = input:size()
	oSize[3] = self.outputSize
	self.output = input.new()
	self.output:resize(oSize)

	if self.train then

		self._cell:resize(oSize)
		self.gradInput:resize(iSize)
		self.otanh:resize(oSize)
		self.oogate:resize(oSize)
		self.ohid:resize(oSize)
		local dOSize = input:size()
		dOSize[3] = self.outputSize * 2
		self.oifgate:resize(dOSize)

	end

	-- ensure cell and output are ready for the first step
	-- set batch size and prepare the cell and output
	local _nIdim = input[1]:nDimension()
	if _nIdim>1 then
		self.batchsize = input[1]:size(1)

		-- if need start from last state of the previous sequence
		if self.rememberState and self.lastCell then
			if self.lastCell:size(1) == self.batchsize then
				self.cell0 = self.lastCell
				self.output0 = self.lastOutput
			else
				self.cell0 = self.lastCell:narrow(1, 1, self.batchsize)
				self.output0 = self.lastOutput:narrow(1, 1, self.batchsize)
			end
		else
			self.cell0 = self.sbm.bias:narrow(1, 1, self.outputSize)
			self.cell0 = self.cell0:reshape(1,self.outputSize):expand(self.batchsize, self.outputSize)
			self.output0 = self.sbm.bias:narrow(1, self.fgstartid, self.outputSize)
			self.output0 = self.output0:reshape(1,self.outputSize):expand(self.batchsize, self.outputSize)
		end

		-- narrow dimension
		self.narrowDim = _nIdim
	else
		self.batchsize = nil

		if self.rememberState and self.lastCell then
			self.cell0 = self.lastCell
			self.output0 = self.lastOutput
		else
			self.cell0 = self.sbm.bias:narrow(1, 1, self.outputSize)
			self.output0 = self.sbm.bias:narrow(1, self.fgstartid, self.outputSize)
		end

		-- narrow dimension
		self.narrowDim = 1
	end
	self.cell = self.cell0
	local _output = self.output0

	-- forward the whole sequence
	for _t = 1, iSize[1] do
		local iv = input[_t]
		-- compute input gate and forget gate
		local _ifgo = self.ifgate:forward({iv, _output, self.cell})

		-- get input gate and forget gate
		local _igo = _ifgo:narrow(self.narrowDim, 1, self.outputSize)
		local _fgo = _ifgo:narrow(self.narrowDim, self.fgstartid, self.outputSize)

		-- compute hidden
		local _ho = self.hmod:forward({iv, _output})

		-- get new value of the cell
		self.cell = torch.add(torch.cmul(_fgo, self.cell),torch.cmul(_igo,_zo))

		-- compute output gate with the new cell,
		-- this is the standard lstm,
		-- otherwise it can be computed with input gate and forget gate
		local _ogo = self.ogate:forward({iv, _output, self.cell})

		-- compute the final output for this input
		local _otanh = self.tanh:forward(self.cell)
		_output = torch.cmul(_ogo, _otanh)

		self.output[_t]:copy(_output)

		-- if training, remember what should remember
		if self.train then
			self._cell[_t]:copy(self.cell)--c[t]
			self.otanh[_t]:copy(_otanh)--tanh[t]
			self.oifgate[_t]:copy(_ifgo)--if[t], input and forget
			self.ohid[_t]:copy(_zo)--h[t]
			self.oogate[_t]:copy(_ogo)--o[t]
		end

	end

	return self.output

end

-- updateOutput for a table sequence
function aGRU:_seq_updateOutput(input)

	self.gradInput = nil

	local output = {}

	-- ensure cell and output are ready for the first step
	-- set batch size and prepare the cell and output
	local _nIdim = input[1]:nDimension()
	if _nIdim>1 then
		self.batchsize = input[1]:size(1)

		-- if need start from last state of the previous sequence
		if self.rememberState and self.lastOutput then
			if self.lastOutput:size(1) == self.batchsize then
				self.output0 = self.lastOutput
			else
				self.output0 = self.lastOutput:narrow(1, 1, self.batchsize)
			end
		else
			self.output0 = self.sbm.bias
			self.output0 = self.output0:reshape(1,self.outputSize):expand(self.batchsize, self.outputSize)
		end

		-- narrow dimension
		self.narrowDim = _nIdim

	else

		self.batchsize = nil

		if self.rememberState and self.lastOutput then
			self.output0 = self.lastOutput
		else
			self.output0 = self.sbm.bias
		end

		-- narrow dimension
		self.narrowDim = 1

	end

	local _output = self.output0

	-- forward the whole sequence
	for _,iv in ipairs(input) do
		-- compute input gate and forget gate
		local _ifgo = self.ifgate:forward({iv, _output})

		-- get input gate and forget gate
		local _igo = _ifgo:narrow(self.narrowDim, 1, self.outputSize)
		local _fgo = _ifgo:narrow(self.narrowDim, self.fgstartid, self.outputSize)

		-- compute reset output
		local _ro = torch.cmul(_output, _fgo)

		-- compute hidden
		local _ho = self.hmod:forward({iv, _ro})

		local _igr = _igo.new()
		_igr:resizeAs(_igo):fill(1):csub(_igo)

		-- compute the final output for this input
		_output = torch.cmul(_igr, _ho) + torch.cmul(_igo, _output)

		table.insert(output, _output)

		-- if training, remember what should remember
		if self.train then
			--table.insert(self._output, _output)--h[t]
			table.insert(self.oifgate, _ifgo)--if[t], input and forget
			table.insert(self.ohid, _ho)-- h[t]
			table.insert(self.oigr, _igr)-- 1-z[t]
			table.insert(self.ro, _ro)-- reset output
		end

	end

	--[[for _,v in ipairs(input) do
		table.insert(output,self:_step_updateOutput(v))
	end]]

	-- this have conflict with _step_updateOutput,
	-- but anyhow do not use them at the same time
	self.output = output
	self._output = output

	--[[if self.train then
		self:_check_table_same(self._cell)
		self:_check_table_same(self._output)
		self:_check_table_same(self.otanh)
		self:_check_table_same(self.oifgate)
		self:_check_table_same(self.ohid)
		self:_check_table_same(self.oogate)
	end]]

	return self.output

end

-- This function was used to check whether the first and second item of a table was same,
-- It was only used during debug time,
-- to prevent all element of a table point to the same thing
--[[function aGRU:_check_table_same(tbin)

	local _rs = true

	if #tbin>2 then
		if tbin[1]:equal(tbin[2]) then
			_rs = false
		end
	end

	if _rs then
		print("pass")
	end

	return _rs

end]]

-- backward for one step,
-- though I do not know when to use this
function aGRU:_step_backward(input, gradOutput, scale)

	-- if need to mask zero, then mask
	if self.maskzero then
		self:_step_makeZero(input, gradOutput)
	end

	local gradInput

	-- grad to cell, gate and input
	local _gCell, _gg, gradInput

	-- if this is not the last step
	if self.__gLOutput then

		-- if this is not the first step
		if #self._output > 0 then

			-- add gradOutput from the sequence behind
			gradOutput:add(self._gLOutput)

			local _cInput = table.remove(input)-- current input
			local _cPrevOutput = table.remove(self._output)-- previous output
			local _cPrevCell = table.remove(self._cell)-- previous cell

			local _cotanh = table.remove(self.otanh)-- output of the tanh after cell for the final output
			local _cofgate = table.remove(self.ofgate)-- output of the forget gate
			local _cougate = table.remove(self.ougate)-- output of the update gate

			-- backward

			-- grad to output gate
			_gg = torch.cmul(gradOutput, _cotanh)

			-- backward output gate
			gradInput, self._gLOutput, _gCell = unpack(self.ogate:backward({_cInput, _cPrevOutput, self.cell}, _gg, scale))

			-- add gradOutput from the sequence behind
			_gCell:add(self._gLCell)

			-- backward from the output tanh to cell
			_gCell:add(self.tanh:updateGradInput(self.cell, torch.cmul(gradOutput, _cPrevOutput)))

			-- backward update gate
			local __gInput, __gLOutput = unpack(self.hmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _cougate), scale))
			gradInput:add(__gInput)
			self._gLOutput:add(__gLOutput)

			-- compute the gradOutput of the Prev cell
			self._gLCell = torch.cmul(_gCell, _cofgate)

			-- backward ifgate(input and forget gate)
			-- compute gradOutput
			_gg:resize(self.batchsize, 2 * self.outputSize)
			_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
			_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cougate))
			-- backward the gate
			__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
			gradInput:add(__gInput)
			self._gLOutput:add(__gLOutput)
			self._gLCell:add(__gLCell)

			-- move self.cell(current cell) ahead
			self.cell = _cPrevCell

		else

			-- for the first step

			-- add gradOutput from the sequence behind
			gradOutput:add(self._gLOutput)

			local _cInput = table.remove(input)-- current input
			local _cPrevOutput = self.output0-- previous output
			local _cPrevCell = self.cell0-- previous cell

			local _cotanh = table.remove(self.otanh)-- output of the tanh after cell for the final output
			local _cofgate = table.remove(self.ofgate)-- output of the forget gate
			local _cougate = table.remove(self.ougate)-- output of the update gate

			-- backward

			-- grad to output gate
			_gg = torch.cmul(gradOutput, _cotanh)
			-- backward output gate
			gradInput, self._gLOutput, _gCell = unpack(self.ogate:backward({_cInput, _cPrevOutput, self.cell}, _gg, scale))

			-- add gradOutput from the sequence behind
			_gCell:add(self._gLCell)

			-- backward from the output tanh to cell
			_gCell:add(self.tanh:updateGradInput(self.cell, torch.cmul(gradOutput, _cPrevOutput)))

			-- backward update gate
			local __gInput, __gLOutput = unpack(self.hmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _cougate), scale))
			gradInput:add(__gInput)
			self._gLOutput:add(__gLOutput)

			-- compute the gradOutput of the Prev cell
			self._gLCell = torch.cmul(_gCell, _cofgate)

			-- backward ifgate(input and forget gate)
			-- compute gradOutput
			_gg:resize(self.batchsize, 2 * self.outputSize)
			_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
			_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cougate))
			-- backward the gate
			__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
			gradInput:add(__gInput)

			-- only while update init cell and output are needed,
			-- this calc for time step 0 are needed
			if not self.rememberState or self.firstSequence then
				self._gLOutput:add(__gLOutput)
				self._gLCell:add(__gLCell)
			end

			if self.rememberState then
				if self.firstSequence then
					-- accGradParameters for self
					self:_accGradParameters(scale)
					self.firstSequence = false
				end
			else
				self:_accGradParameters(scale)
			end

			-- prepare for next forward sequence, clear cache
			self:clearState()

		end

	else

		-- for the last step

		-- whether the last step also was the first step
		local _also_first = false
		if #self._output ==1 then
			_also_first = true
		end

		-- remove the last output
		local _lastOutput = table.remove(self._output)
		-- get current cell,
		-- it will be used will backward output gate
		self.cell = table.remove(self._cell)

		-- if need to remember to use for the next sequence
		if self.rememberState then
			self.lastCell = self.cell
			self.lastOutput = _lastOutput
		end

		--backward the last

		-- prepare data for future use
		local _cInput = table.remove(input)-- current input
		local _cPrevOutput,_cPrevCell

		if _also_first then
			_cPrevOutput = self.output0
			_cPrevCell = self.cell0
		else
			_cPrevOutput = table.remove(self._output)-- previous output
			_cPrevCell = table.remove(self._cell)-- previous cell
		end

		local _cotanh = table.remove(self.otanh)-- output of the tanh after cell for the final output
		local _cofgate = table.remove(self.ofgate)-- output of the forget gate
		local _cougate = table.remove(self.ougate)-- output of the update gate

		-- backward

		-- grad to output gate
		_gg = torch.cmul(gradOutput, _cotanh)

		-- backward output gate
		gradInput, self._gLOutput, _gCell = unpack(self.ogate:backward({_cInput, _cPrevOutput, self.cell}, _gg, scale))

		-- backward from the output tanh to cell
		_gCell:add(self.tanh:updateGradInput(self.cell, torch.cmul(gradOutput, _cPrevOutput)))

		-- backward update gate
		local __gInput, __gLOutput = unpack(self.hmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _cougate), scale))
		gradInput:add(__gInput)
		self._gLOutput:add(__gLOutput)

		-- compute the gradOutput of the Prev cell
		self._gLCell = torch.cmul(_gCell, _cofgate)

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cougate))
		-- backward the gate
		local __gLCell
		__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
		gradInput:add(__gInput)

		if not _also_first then
			if not self.rememberState or self.firstSequence then
				self._gLOutput:add(__gLOutput)
				self._gLCell:add(__gLCell)
			end
			-- move self.cell(current cell) ahead
			self.cell = _cPrevCell
		else
			if self.rememberState then
				if self.firstSequence then
					-- accGradParameters for self
					self:_accGradParameters(scale)
					self.firstSequence = false
				end
			else
				self:_accGradParameters(scale)
			end
			self:clearState()
		end

	end

	-- this have conflict with _table_seq_backward,
	-- but anyhow do not use them at the same time
	self.gradInput = gradInput

	return self.gradInput

end

-- backward process the whole sequence
-- it takes the whole input, gradOutput sequence as input
-- and it will clear the cache after done backward
function aGRU:_seq_backward(input, gradOutput, scale)

	self.output = nil

	-- if need to mask zero, then mask
	if self.maskzero then
		self:_seq_makeZero(input, gradOutput)
	end

	local _length = #input

	-- reference clone the input table,
	-- otherwise it will be cleaned during backward
	local _input = self:_cloneTable(input)

	local gradInput = {}

	-- remove the last output, because it was never used
	local _lastOutput = table.remove(self._output)

	-- remember the end of sequence for next input use
	if self.rememberState then
		self.lastOutput = _lastOutput
	end

	-- grad to input
	local _gInput

	-- temp storage
	local __gInput, __gLOutput

	-- pre claim the local variable, they were discribed where they were used.
	local _cGradOut, _cInput, _cPrevOutput, _coifgate, _coh, _coigate, _cofgate, _gg, _coigr, _cro, _gro

	if _length > 1 then

		--backward the last

		-- prepare data for future use
		_cGradOut = table.remove(gradOutput)-- current gradOutput
		_cInput = table.remove(_input)-- current input
		_cPrevOutput = table.remove(self._output)-- previous output, s[t-1]

		_coh = table.remove(self.ohid)-- hidden unit produced by input, h[t]
		_coigr = table.remove(self.oigr)-- 1-z[t]
		_cro = table.remove(self.ro)-- reset output
		_coifgate = table.remove(self.oifgate)-- output of the input and forget gate, if[t], input and forget

		-- asign output of input gate and output gate
		_coigate = _coifgate:narrow(self.narrowDim, 1, self.outputSize)-- i[t]
		_cofgate = _coifgate:narrow(self.narrowDim, self.fgstartid, self.outputSize)--f[t] 

		-- backward

		-- backward hidden
		_gInput, _gro = unpack(self.hmod:backward({_cInput, _cro}, torch.cmul(_cGradOut, _coigr), scale))-- gradient on input and reset of previous output

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gro, _cPrevOutput))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_cGradOut, _cPrevOutput - _coh))
		-- backward the gate

		__gInput, self._gLOutput = unpack(self.ifgate:backward({_cInput, _cPrevOutput}, _gg, scale))
		_gInput:add(__gInput)
		self._gLOutput:add(torch.cmul(_gro, _cofgate))
		self._gLOutput:add(torch.cmul(_cGradOut, _cPrevOutput))

		gradInput[_length] = _gInput:clone()

	else

		-- prepare self._gLOutput for it will be used by the first step
		-- zero here results extra resource waste,
		-- but it is ok if it was not a often case
		self._gLOutput = gradOutput[1]:clone():zero()

	end

	-- backward from end to 2
	for _t = _length - 1, 2, -1 do

		-- prepare data for future use
		_cGradOut = table.remove(gradOutput)-- current gradOutput
		-- add gradOutput from the sequence behind
		_cGradOut:add(self._gLOutput)

		_cInput = table.remove(_input)-- current input
		_cPrevOutput = table.remove(self._output)-- previous output, s[t-1]

		_coh = table.remove(self.ohid)-- hidden unit produced by input, h[t]
		_coigr = table.remove(self.oigr)-- 1-z[t]
		_cro = table.remove(self.ro)-- reset output
		_coifgate = table.remove(self.oifgate)-- output of the input and forget gate, if[t], input and forget

		-- asign output of input gate and output gate
		_coigate = _coifgate:narrow(self.narrowDim, 1, self.outputSize)-- i[t]
		_cofgate = _coifgate:narrow(self.narrowDim, self.fgstartid, self.outputSize)--f[t] 

		-- backward

		-- backward hidden
		_gInput, _gro = unpack(self.hmod:backward({_cInput, _cro}, torch.cmul(_cGradOut, _coigr), scale))-- gradient on input and reset of previous output

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gro, _cPrevOutput))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_cGradOut, _cPrevOutput - _coh))
		-- backward the gate

		__gInput, self._gLOutput = unpack(self.ifgate:backward({_cInput, _cPrevOutput}, _gg, scale))
		_gInput:add(__gInput)
		self._gLOutput:add(torch.cmul(_gro, _cofgate))
		self._gLOutput:add(torch.cmul(_cGradOut, _cPrevOutput))

		gradInput[_t] = _gInput:clone()

	end

	-- backward for the first time step

	-- prepare data for future use
	_cGradOut = table.remove(gradOutput)-- current gradOutput
	-- add gradOutput from the sequence behind
	_cGradOut:add(self._gLOutput)

	_cInput = table.remove(_input)-- current input
	_cPrevOutput = table.remove(self._output)-- previous output, s[t-1]

	_coh = table.remove(self.ohid)-- hidden unit produced by input, h[t]
	_coigr = table.remove(self.oigr)-- 1-z[t]
	_cro = table.remove(self.ro)-- reset output
	_coifgate = table.remove(self.oifgate)-- output of the input and forget gate, if[t], input and forget

	-- asign output of input gate and output gate
	_coigate = _coifgate:narrow(self.narrowDim, 1, self.outputSize)-- i[t]
	_cofgate = _coifgate:narrow(self.narrowDim, self.fgstartid, self.outputSize)--f[t] 

	-- backward

	-- backward hidden
	_gInput, _gro = unpack(self.hmod:backward({_cInput, _cro}, torch.cmul(_cGradOut, _coigr), scale))-- gradient on input and reset of previous output

	-- backward ifgate(input and forget gate)
	-- compute gradOutput
	_gg:resize(self.batchsize, 2 * self.outputSize)
	_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gro, _cPrevOutput))
	_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_cGradOut, _cPrevOutput - _coh))
	-- backward the gate

	__gInput, self._gLOutput = unpack(self.ifgate:backward({_cInput, _cPrevOutput}, _gg, scale))
	_gInput:add(__gInput)
	self._gLOutput:add(torch.cmul(_gro, _cofgate))
	self._gLOutput:add(torch.cmul(_cGradOut, _cPrevOutput))

	gradInput[1] = _gInput

	-- accGradParameters for self
	if self.rememberState then

		if self.firstSequence then
			-- accGradParameters for self
			self:_accGradParameters(scale)
			self.firstSequence = false
		end

		-- prepare for next forward sequence, clear cache
		self:clearState()

	else
		self:_accGradParameters(scale)

		self:forget()

	end


	self.gradInput = gradInput

	return self.gradInput

end

-- backward for tensor input and gradOutput sequence
function aGRU:_tseq_backward(input, gradOutput, scale)

	-- if need to mask zero, then mask
	if self.maskzero then
		self:_tseq_makeZero(input, gradOutput)
	end

	local iSize = input:size()
	local oSize = gradOutput:size()

	local _length = iSize[1]

	local gradInput = input.new()
	gradInput:resize(iSize)

	-- remove the last output, because it was never used
	local _lastOutput = self.output[_length]
	-- get current cell,
	-- it will be used will backward output gate
	self.cell = self._cell[_length]--c[t]

	-- remember the end of sequence for next input use
	if self.rememberState then
		-- clone it, for fear that self.lastCell and self.lastOutput marks the whole memory of self.cell and self.output as used
		self.lastCell = self.cell:clone()
		self.lastOutput = _lastOutput:clone()
	end

	-- grad to input and cell
	local _gInput, _gCell

	-- pre claim the local variable, they were discribed where they were used.
	local _cGradOut, _cInput, _cPrevOutput, _cPrevCell, _cotanh, _coifgate, _coogate, _coh, _coigate, _cofgate, _gg
	local __gLCell

	if _length > 1 then

		--backward the last

		-- prepare data for future use
		_cGradOut = gradOutput[_length]-- current gradOutput
		_cInput = input[_length]-- current input
		_cPrevOutput = self.output[_length - 1]-- previous output, h[t-1]
		_cPrevCell = self._cell[_length - 1]-- previous cell, c[t-1]

		_cotanh = self.otanh[_length]-- output of the tanh after cell for the final output, tanh[t]
		_coifgate = self.oifgate[_length]-- output of the input and forget gate, if[t], input and forget
		_coogate = self.oogate[_length]-- output of the output gate, o[t]
		_coh = self.ohid[_length]-- hidden unit produced by input, z[t]

		-- asign output of input gate and output gate
		_coigate = _coifgate:narrow(self.narrowDim, 1, self.outputSize)-- i[t]
		_cofgate = _coifgate:narrow(self.narrowDim, self.fgstartid, self.outputSize)--f[t] 

		-- backward

		-- grad to output gate
		_gg = torch.cmul(_cGradOut, _cotanh)

		-- backward output gate

		_gInput, self._gLOutput, _gCell = unpack(self.ogate:backward({_cInput, _cPrevOutput, self.cell}, _gg, scale))

		-- backward from the output tanh to cell
		_gCell:add(self.tanh:updateGradInput(self.cell, torch.cmul(_cGradOut, _coogate)))

		-- backward hidden
		local __gInput, __gLOutput = unpack(self.hmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _coigate), scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)

		-- compute the gradOutput of the Prev cell
		self._gLCell = torch.cmul(_gCell, _cofgate)

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _coh))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
		-- backward the gate

		__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)
		self._gLCell:add(__gLCell)

		-- move self.cell(current cell) ahead,
		-- prepare to backward on time step before
		self.cell = _cPrevCell

		gradInput[_length]:copy(_gInput)

	else

		-- prepare self._gLOutput and self.__gLCell for it will be used by the first step
		-- zero here result extra resource waste,
		-- but it is ok if it was not a often case
		self._gLOutput = gradOutput[1]:clone():zero()
		self._gLCell = self._gLOutput:clone()

	end

	-- backward from end to 2
	for _t = _length - 1, 2, -1 do

		-- prepare data for future use
		_cGradOut = gradOutput[_t]-- current gradOutput

		-- add gradOutput from the sequence behind
		_cGradOut:add(self._gLOutput)

		_cInput = input[_t]-- current input
		_cPrevOutput = self.output[_t - 1]-- previous output
		_cPrevCell = self._cell[_t - 1]-- previous cell

		_cotanh = self.otanh[_t]-- output of the tanh after cell for the final output
		_coifgate = self.oifgate[_t]-- output of the input and forget gate
		_coogate = self.oogate[_t]-- output of the output gate
		_coh = self.ohid[_t]-- hidden unit produced by input

		-- asign output of input gate and output gate
		_coigate = _coifgate:narrow(self.narrowDim, 1, self.outputSize) 
		_cofgate = _coifgate:narrow(self.narrowDim, self.fgstartid, self.outputSize) 

		-- backward

		-- grad to output gate
		_gg = torch.cmul(_cGradOut, _cotanh)

		-- backward output gate
		_gInput, self._gLOutput, _gCell = unpack(self.ogate:backward({_cInput, _cPrevOutput, self.cell}, _gg, scale))

		-- backward from the output tanh to cell
		_gCell:add(self.tanh:updateGradInput(self.cell, torch.cmul(_cGradOut, _coogate)))

		-- add gradOutput from the sequence behind
		_gCell:add(self._gLCell)

		-- backward hidden
		local __gInput, __gLOutput = unpack(self.hmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _coigate), scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)

		-- compute the gradOutput of the Prev cell
		self._gLCell = torch.cmul(_gCell, _cofgate)

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _coh))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
		-- backward the gate
		__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)
		self._gLCell:add(__gLCell)

		-- move self.cell(current cell) ahead
		self.cell = _cPrevCell

		gradInput[_t]:copy(_gInput)

	end

	-- backward for the first time step

	-- prepare data for future use
	_cGradOut = gradOutput[1]-- current gradOutput

	-- add gradOutput from the sequence behind
	_cGradOut:add(self._gLOutput)

	_cInput = input[1]-- current input
	_cPrevOutput = self.output0-- previous output
	_cPrevCell = self.cell0-- previous cell

	_cotanh = self.otanh[1]-- output of the tanh after cell for the final output

	_coifgate = self.oifgate[1]-- output of the input and forget gate
	_coogate = self.oogate[1]-- output of the output gate
	_coh = self.ohid[1]-- hidden unit produced by input

	-- asign output of input gate and output gate
	_coigate = _coifgate:narrow(self.narrowDim, 1, self.outputSize) 
	_cofgate = _coifgate:narrow(self.narrowDim, self.fgstartid, self.outputSize)

	-- backward

	-- grad to output gate
	_gg = torch.cmul(_cGradOut, _cotanh)
	-- backward output gate
	_gInput, self._gLOutput, _gCell = unpack(self.ogate:backward({_cInput, _cPrevOutput, self.cell}, _gg, scale))

	-- backward from the output tanh to cell
	_gCell:add(self.tanh:updateGradInput(self.cell, torch.cmul(_cGradOut, _coogate)))

	-- add gradOutput from the sequence behind
	_gCell:add(self._gLCell)

	-- backward hidden
	__gInput, __gLOutput = unpack(self.hmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _coigate), scale))
	_gInput:add(__gInput)
	self._gLOutput:add(__gLOutput)

	-- compute the gradOutput of the Prev cell
	self._gLCell = torch.cmul(_gCell, _cofgate)

	-- backward ifgate(input and forget gate)
	-- compute gradOutput
	_gg:resize(self.batchsize, 2 * self.outputSize)
	_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _coh))
	_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
	-- backward the gate
	__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
	_gInput:add(__gInput)

	-- accGradParameters for self
	if self.rememberState then

		if self.firstSequence then
			-- accGradParameters for self
			self._gLOutput:add(__gLOutput)
			self._gLCell:add(__gLCell)
			self:_accGradParameters(scale)
			self.firstSequence = false
		end

		-- prepare for next forward sequence, clear cache
		self:clearState()

	else

		self._gLOutput:add(__gLOutput)
		self._gLCell:add(__gLCell)
		self:_accGradParameters(scale)

		self:forget()

	end

	self.gradInput:resizeAs(gradInput):copy(gradInput)

	return self.gradInput

end

-- updateGradInput for sequence,
-- in fact, it call backward
function aGRU:_seq_updateGradInput(input, gradOutput)

	return self:backward(input, gradOutput)

end

-- modules in aGRU.modules were done while backward
function aGRU:accGradParameters(input, gradOutput, scale)

	if self.rememberState then
		if self.firstSequence then
			-- accGradParameters for self
			self:_accGradParameters(scale)
			self.firstSequence = false
		end
	else
		self:_accGradParameters(scale)
	end

end

-- updateParameters 
--[[function aGRU:updateParameters(learningRate)

	for _, module in ipairs(self.modules) do
		module:updateParameters(learningRate)
	end
	self.sbm.bias:add(-learningRate, self.sbm.gradBias)

end]]

-- zeroGradParameters
--[[function aGRU:zeroGradParameters()

	for _, module in ipairs(self.modules) do
		module:zeroGradParameters()
	end
	self.sbm.gradBias:zero()

end]]

-- accGradParameters used for aGRU.bias
function aGRU:_accGradParameters(scale)

	scale = scale or 1
	if self.batchsize then
		self._gLOutput = self._gLOutput:sum(1)
		self._gLOutput:resize(self.outputSize)
	end
	self.sbm.gradBias:add(scale, self._gLOutput)

end

-- init storage for tensor
function aGRU:_tensor_clearState(tsr)

	tsr = tsr or self.sbm.bias

	-- output sequence
	if not self.output then
		self.output = tsr.new()
	else
		self.output:resize(0)
	end

	-- last output
	-- here switch the usage of self.output and self._output for fit the standard of nn.Module
	-- just point self._output to keep aGRU standard
	self._output = self.output

	-- gradInput sequence
	if not self.gradInput then
		self.gradInput = tsr.new()
	else
		self.gradInput:resize(0)
	end

	-- output of the input and forget gate
	if not self.oifgate then
		self.oifgate = tsr.new()
	else
		self.oifgate:resize(0)
	end

	-- output of z(hidden)
	if not self.ohid then
		self.ohid = tsr.new()
	else
		self.ohid:resize(0)
	end

	-- 1-z[t]
	if not self.oigr then
		self.oigr = tsr.new()
	else
		self.oigr:resize(0)
	end

	-- reset output
	if not self.ro then
		self.ro = tsr.new()
	else
		self.ro:resize(0)
	end

	-- grad from the sequence after
	self._gLOutput = nil

end

-- clear the storage
function aGRU:_table_clearState()

	-- output sequence
	self._output = {}
	-- last output
	self.output = nil
	-- gradInput sequence
	self.gradInput = nil

	-- output of the input and forget gate
	self.oifgate = {}
	-- output of z(hidden)
	self.ohid = {}
	-- 1-z[t]
	self.oigr = {}
	-- reset output
	self.ro = {}

	-- grad from the sequence after
	self._gLOutput = nil

end

-- forget the history
function aGRU:forget()

	self:clearState()

	for _, module in ipairs(self.modules) do
		module:forget()
	end

	-- clear last cell and output
	self.lastCell = nil
	self.lastOutput = nil

	-- set first sequence(will update bias)
	self.firstSequence = true

end

-- define type
function aGRU:type(type, ...)

	return parent.type(self, type, ...)

end

-- evaluate
function aGRU:evaluate()

	self.train = false

	for _, module in ipairs(self.modules) do
		module:evaluate()
	end

	self:forget()

end

-- train
function aGRU:training()

	self.train = true

	for _, module in ipairs(self.modules) do
		module:training()
	end

	self:forget()

end

-- reset the module
function aGRU:reset()

	self.ifgate = self:buildIFModule()
	self.hmod = self:buildUpdateModule()

	-- inner parameters need to correctly processed
	-- in fact, it is output and cell at time step 0
	-- it contains by a module to fit Container
	self.sbm = self:buildSelfBias(self.outputSize)

	--[[ put the modules in self.modules,
	so the default method could be done correctly]]
	self.modules = {self.ifgate, self.hmod, self.sbm}

	self:forget()

end

-- remember last state or not
function aGRU:remember(mode)

	-- set default to both
	local _mode = mode or "both"

	if _mode == "both" or _mode == true then
		self.rememberState = true
	else
		self.rememberState = nil
	end

	self:forget()

end

-- build input and forget gate
function aGRU:buildIFModule()

	local _ifm = nn.aSequential()
		:add(nn.aJoinTable(self.narrowDim,self.narrowDim))
		:add(nn.aLinear(self.inputSize + self.outputSize, self.outputSize * 2))
		:add(nn.aSigmoid(true))

	return _ifm

end

-- build z(update) module
function aGRU:buildUpdateModule()

	local _um = nn.aSequential()
		:add(nn.aJoinTable(self.narrowDim,self.narrowDim))
		:add(nn.aLinear(self.inputSize + self.outputSize, self.outputSize))
		:add(nn.aTanh(true))

	return _um

end

-- build a module that contains aGRU.bias and aGRU.gradBias to make it fit Container
function aGRU:buildSelfBias(outputSize)

	local _smb = nn.Module()
	_smb.bias = torch.zeros(outputSize)
	_smb.gradBias = _smb.bias:clone()

	return _smb

end

-- prepare for LSTM
function aGRU:prepare()

	-- Warning: This method may be DEPRECATED at any time
	-- it is for debug use
	-- you should write a faster and simpler module instead of nn
	-- for your particular use

	nn.aJoinTable = nn.JoinTable
	nn.aLinear = nn.Linear

	-- Warning: Use Sequence Tanh and Sigmoid are fast
	-- but be very very cautious!!!
	-- you need to give it an argument true,
	-- if you need it work in reverse order
	-- and you must turn to evaluate state if you were evaluate,
	-- otherwise the output are remembered!
	require "aSeqTanh"
	nn.aTanh = nn.aSeqTanh
	--nn.aTanh = nn.Tanh
	require "aSeqSigmoid"
	nn.aSigmoid = nn.aSeqSigmoid
	--nn.aSigmoid = nn.Sigmoid
	--[[require "aSTTanh"
	require "aSTSigmoid"
	nn.aTanh = nn.aSTTanh
	nn.aSigmoid = nn.aSTSigmoid]]
	nn.aSequential = nn.Sequential

end

-- mask zero for a step
function aGRU:_step_makeZero(input, gradOutput)

	if self.batchsize then
		-- if batch input
		
		-- get a zero unit
		local _stdZero = input.new()
		_stdZero:resizeAs(input[1]):zero()
		-- look at each unit
		for _t = 1, self.batchsize do
			if input[_t]:equal(_stdZero) then
				-- if it was zero, then zero the gradOutput
				gradOutput[_t]:zero()
			end
		end
	else
		-- if not batch

		local _stdZero = input.new()
		_stdZero:resizeAs(input):zero()
		if input:equal(_stdZero) then
			gradOutput:zero()
		end
	end

end

-- mask zero for a sequence
function aGRU:_seq_makeZero(input, gradOutput)

	-- get a storage
	local _fi = input[1]
	local _stdZero = _fi.new()

	if self.batchsize then
	-- if batch input

		-- get a zero unit
		_stdZero:resizeAs(_fi[1]):zero()

		-- walk the whole sequence
		for _t,v in ipairs(input) do
			-- make zero for each step
			-- look at each unit
			local _grad = gradOutput[_t]
			for __t = 1, self.batchsize do
				if v[__t]:equal(_stdZero) then
					-- if it was zero, then zero the gradOutput
					_grad[__t]:zero()
				end
			end
		end

	else

		_stdZero:resizeAs(_fi):zero()

		-- walk the whole sequence
		for _t,v in ipairs(input) do
			-- make zero for each step
			-- look at each unit
			if v:equal(_stdZero) then
				-- if it was zero, then zero the gradOutput
				gradOutput[_t]:zero()
			end
		end

	end

end

-- mask zero for a tensor sequence
function aGRU:_tseq_makeZero(input, gradOutput)

	local _fi = input[1][1]
	local iSize = input:size()
	local _stdZero = _fi.new()
	_stdZero:resizeAs(_fi):zero()
	for _i = 1, iSize[1] do
		local _ti = input[_i]
		for _j= 1, iSize[2] do
			if _ti[_j]:equal(_stdZero) then
				gradOutput[_i][_j]:zero()
			end
		end
	end

end

-- copy a table
function aGRU:_cloneTable(tbsrc)

	local tbrs = {}

	for k,v in ipairs(tbsrc) do
		tbrs[k] = v
	end

	return tbrs
end

-- introduce self
function aGRU:__tostring__()

	return string.format('%s(%d -> %d)', torch.type(self), self.inputSize, self.outputSize)

end
