--[[
	The GNU GENERAL PUBLIC LICENSE Version 3

	Copyright (c) 2016 Hongfei Xu

	This scripts implement a standard vanilla LSTM:

	i[t] = σ(W[x->i]x[t] + W[h->i]h[t−1] + W[c->i]c[t−1] + b[1->i])      (1)
	f[t] = σ(W[x->f]x[t] + W[h->f]h[t−1] + W[c->f]c[t−1] + b[1->f])      (2)
	z[t] = tanh(W[x->c]x[t] + W[h->c]h[t−1] + b[1->c])                   (3)
	c[t] = f[t]c[t−1] + i[t]z[t]                                         (4)
	o[t] = σ(W[x->o]x[t] + W[h->o]h[t−1] + W[c->o]c[t] + b[1->o])        (5)
	h[t] = o[t]tanh(c[t])                                                (6)

	Version 0.0.5

]]

local aLSTM, parent = torch.class('nn.aLSTM', 'nn.Container')

function aLSTM:__init(inputSize, outputSize, maskZero, remember)

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
	self:_asign()

	-- forget gate start index
	-- also was used in updateOutput to prepare init cell and output,
	-- because it is outputSize + 1, take care of this
	self.fgstartid = outputSize + 1

	-- prepare to build the modules
	self.inputSize, self.outputSize = inputSize, outputSize

	self.narrowDim = 1

	self:reset()

end

-- asign default method
function aLSTM:_asign()

	self.updateOutput = self._seq_updateOutput
	self.backward = self._seq_backward
	self.updateGradInput = self._seq_updateGradInput

end

-- updateOutput called by forward,
-- It input a time step's input and produce an output
function aLSTM:_step_updateOutput(input)

	-- ensure cell and output are ready for the first step
	if not self.cell then
		-- set batch size and prepare the cell and output
		local _nIdim = input:nDimension()
		if _nIdim>1 then
			self.batchsize = input:size(1)

			if self.rememberState and self.lastCell then
				self.cell0 = self.lastCell:narrow(1, 1, self.batchsize)
				self.output0 = self.lastOutput:narrow(1, 1, self.batchsize)
			else
				self.cell0 = torch.repeatTensor(self.sbm.bias:narrow(1, 1, self.outputSize), self.batchsize, 1)
				self.output0 = torch.repeatTensor(self.sbm.bias:narrow(1, self.fgstartid, self.outputSize), self.batchsize, 1)
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
	local _zo = self.zmod:forward({input, self.output})

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
		table.insert(self.ougate, _zo)
	end

	-- return the output for this input
	return self.output

end

-- updateOutput for a table sequence
function aLSTM:_seq_updateOutput(input)

	local output = {}

	-- ensure cell and output are ready for the first step
	-- set batch size and prepare the cell and output
	local _nIdim = input[1]:nDimension()
	if _nIdim>1 then
		self.batchsize = input[1]:size(1)

		-- if need start from last state of the previous sequence
		if self.rememberState and self.lastCell then
			self.cell0 = self.lastCell:narrow(1, 1, self.batchsize)
			self.output0 = self.lastOutput:narrow(1, 1, self.batchsize)
		else
			self.cell0 = torch.repeatTensor(self.sbm.bias:narrow(1, 1, self.outputSize), self.batchsize, 1)
			self.output0 = torch.repeatTensor(self.sbm.bias:narrow(1, self.fgstartid, self.outputSize), self.batchsize, 1)
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
	for _,iv in ipairs(input) do
		-- compute input gate and forget gate
		local _ifgo = self.ifgate:forward({iv, _output, self.cell})

		-- get input gate and forget gate
		local _igo = _ifgo:narrow(self.narrowDim, 1, self.outputSize)
		local _fgo = _ifgo:narrow(self.narrowDim, self.fgstartid, self.outputSize)

		-- compute hidden
		local _zo = self.zmod:forward({iv, _output})

		-- get new value of the cell
		self.cell = torch.add(torch.cmul(_fgo, self.cell),torch.cmul(_igo,_zo))

		-- compute output gate with the new cell,
		-- this is the standard lstm,
		-- otherwise it can be computed with input gate and forget gate
		local _ogo = self.ogate:forward({iv, _output, self.cell})

		-- compute the final output for this input
		local _otanh = self.tanh:forward(self.cell)
		_output = torch.cmul(_ogo, _otanh)

		table.insert(output, _output)

		-- if training, remember what should remember
		if self.train then
			table.insert(self._cell, self.cell)--c[t]
			table.insert(self._output, _output)--h[t]
			table.insert(self.otanh, _otanh)--tanh[t]
			table.insert(self.oifgate, _ifgo)--if[t], input and forget
			table.insert(self.ohid, _zo)--z[t]
			table.insert(self.oogate, _ogo)--o[t]
		end

	end

	--[[for _,v in ipairs(input) do
		table.insert(output,self:_step_updateOutput(v))
	end]]

	-- this have conflict with _step_updateOutput,
	-- but anyhow do not use them at the same time
	self.output = output

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
--[[function aLSTM:_check_table_same(tbin)

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
function aLSTM:_step_backward(input, gradOutput, scale)

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
			local __gInput, __gLOutput = unpack(self.zmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _cougate), scale))
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
			local __gInput, __gLOutput = unpack(self.zmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _cougate), scale))
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

			if self.firstSequence then
				-- accGradParameters for self
				self:_accGradParameters(scale)
				self.firstSequence = false
			end

			-- prepare for next forward sequence, clear cache
			self:_forget()

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
		local __gInput, __gLOutput = unpack(self.zmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _cougate), scale))
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
		self._gLOutput:add(__gLOutput)
		self._gLCell:add(__gLCell)

		if not _also_first then
			-- move self.cell(current cell) ahead
			self.cell = _cPrevCell
		else
			if self.firstSequence then
				self:_accGradParameters(scale)
				self.firstSequence = false
			end
			self:_forget()
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
function aLSTM:_seq_backward(input, gradOutput, scale)

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
	-- get current cell,
	-- it will be used will backward output gate
	self.cell = table.remove(self._cell)--c[t]

	-- remember the end of sequence for next input use
	if self.rememberState then
		self.lastCell = self.cell
		self.lastOutput = _lastOutput
	end

	-- grad to input and cell
	local _gInput, _gCell

	-- pre claim the local variable, they were discribed where they were used.
	local _cGradOut, _cInput, _cPrevOutput, _cPrevCell, _cotanh, _coifgate, _coogate, _coz, _coigate, _cofgate, _gg
	local __gLCell

	if _length > 1 then

		--backward the last

		-- prepare data for future use
		_cGradOut = table.remove(gradOutput)-- current gradOutput
		_cInput = table.remove(_input)-- current input
		_cPrevOutput = table.remove(self._output)-- previous output, h[t-1]
		_cPrevCell = table.remove(self._cell)-- previous cell, c[t-1]

		_cotanh = table.remove(self.otanh)-- output of the tanh after cell for the final output, tanh[t]
		_coifgate = table.remove(self.oifgate)-- output of the input and forget gate, if[t], input and forget
		_coogate = table.remove(self.oogate)-- output of the output gate, o[t]
		_coz = table.remove(self.ohid)-- hidden unit produced by input, z[t]

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
		local __gInput, __gLOutput = unpack(self.zmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _coigate), scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)

		-- compute the gradOutput of the Prev cell
		self._gLCell = torch.cmul(_gCell, _cofgate)

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _coz))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
		-- backward the gate

		__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)
		self._gLCell:add(__gLCell)

		-- move self.cell(current cell) ahead,
		-- prepare to backward on time step before
		self.cell = _cPrevCell

		gradInput[_length] = _gInput:clone()

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
		_cGradOut = table.remove(gradOutput)-- current gradOutput

		-- add gradOutput from the sequence behind
		_cGradOut:add(self._gLOutput)

		_cInput = table.remove(_input)-- current input
		_cPrevOutput = table.remove(self._output)-- previous output
		_cPrevCell = table.remove(self._cell)-- previous cell

		_cotanh = table.remove(self.otanh)-- output of the tanh after cell for the final output
		_coifgate = table.remove(self.oifgate)-- output of the input and forget gate
		_coogate = table.remove(self.oogate)-- output of the output gate
		_coz = table.remove(self.ohid)-- hidden unit produced by input

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
		local __gInput, __gLOutput = unpack(self.zmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _coigate), scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)

		-- compute the gradOutput of the Prev cell
		self._gLCell = torch.cmul(_gCell, _cofgate)

		-- backward ifgate(input and forget gate)
		-- compute gradOutput
		_gg:resize(self.batchsize, 2 * self.outputSize)
		_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _coz))
		_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
		-- backward the gate
		__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
		_gInput:add(__gInput)
		self._gLOutput:add(__gLOutput)
		self._gLCell:add(__gLCell)

		-- move self.cell(current cell) ahead
		self.cell = _cPrevCell

		gradInput[_t] = _gInput:clone()

	end

	-- backward for the first time step

	-- prepare data for future use
	_cGradOut = table.remove(gradOutput)-- current gradOutput

	-- add gradOutput from the sequence behind
	_cGradOut:add(self._gLOutput)

	_cInput = table.remove(_input)-- current input
	_cPrevOutput = self.output0-- previous output
	_cPrevCell = self.cell0-- previous cell

	_cotanh = table.remove(self.otanh)-- output of the tanh after cell for the final output

	_coifgate = table.remove(self.oifgate)-- output of the input and forget gate
	_coogate = table.remove(self.oogate)-- output of the output gate
	_coz = table.remove(self.ohid)-- hidden unit produced by input

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
	__gInput, __gLOutput = unpack(self.zmod:backward({_cInput, _cPrevOutput}, torch.cmul(_gCell, _coigate), scale))
	_gInput:add(__gInput)
	self._gLOutput:add(__gLOutput)

	-- compute the gradOutput of the Prev cell
	self._gLCell = torch.cmul(_gCell, _cofgate)

	-- backward ifgate(input and forget gate)
	-- compute gradOutput
	_gg:resize(self.batchsize, 2 * self.outputSize)
	_gg:narrow(self.narrowDim, 1, self.outputSize):copy(torch.cmul(_gCell, _coz))
	_gg:narrow(self.narrowDim, self.fgstartid, self.outputSize):copy(torch.cmul(_gCell, _cPrevCell))
	-- backward the gate
	__gInput, __gLOutput, __gLCell = unpack(self.ifgate:backward({_cInput, _cPrevOutput, _cPrevCell}, _gg, scale))
	_gInput:add(__gInput)
	self._gLOutput:add(__gLOutput)
	self._gLCell:add(__gLCell)

	gradInput[1] = _gInput

	-- accGradParameters for self
	if self.firstSequence then
		self:_accGradParameters(scale)
		self.firstSequence = false
	end

	-- prepare for next forward sequence, clear cache
	self:_forget()

	self.gradInput = gradInput

	return self.gradInput

end

function aLSTM:_seq_updateGradInput(input, gradOutput)

	return self:backward(input, gradOutput)

end

-- modules in aLSTM.modules were done while backward
function aLSTM:accGradParameters(input, gradOutput, scale)

	if self.firstSequence then
		self:_accGradParameters(scale)
		self.firstSequence = false
	end

end

-- updateParameters 
--[[function aLSTM:updateParameters(learningRate)

	for _, module in ipairs(self.modules) do
		module:updateParameters(learningRate)
	end
	self.sbm.bias:add(-learningRate, self.sbm.gradBias)

end]]

-- zeroGradParameters
--[[function aLSTM:zeroGradParameters()

	for _, module in ipairs(self.modules) do
		module:zeroGradParameters()
	end
	self.sbm.gradBias:zero()

end]]

-- accGradParameters used for aLSTM.bias
function aLSTM:_accGradParameters(scale)

	scale = scale or 1
	if self.batchsize then
		self._gLCell = self._gLCell:sum(1)
		self._gLCell:resize(self.outputSize)
		self._gLOutput = self._gLOutput:sum(1)
		self._gLOutput:resize(self.outputSize)
	end
	self.sbm.gradBias:narrow(1,1,self.outputSize):add(scale, self._gLCell)
	self.sbm.gradBias:narrow(1,self.fgstartid,self.outputSize):add(scale, self._gLOutput)


end

-- clear the storage
function aLSTM:_forget()

	-- cell sequence
	self._cell = {}
	-- last cell
	self.cell = nil
	-- output sequence
	self._output = {}
	-- last output
	self.output = nil
	-- gradInput sequence
	self.gradInput = nil

	-- after tanh value for the final output from cell
	self.otanh = {}
	-- output of the input and forget gate
	self.oifgate = {}
	-- output of the output gate
	self.oogate = {}
	-- output of z(hidden)
	self.ohid = {}

	-- grad from the sequence after
	self._gLCell = nil
	self._gLOutput = nil

end

function aLSTM:forget()

	self:_forget()

	-- clear last cell and output
	self.lastCell = nil
	self.lastOutput = nil

	-- set first sequence(will update bias)
	self.firstSequence = true

end

-- define type
function aLSTM:type(type, ...)
	return parent.type(self, type, ...)
end

-- evaluate
function aLSTM:evaluate()
	self.train = false
	self:_forget()
	for _, module in ipairs(self.modules) do
		module:evaluate()
	end
end

-- train
function aLSTM:training()
	self.train = true
	for _, module in ipairs(self.modules) do
		module:training()
	end
end

-- reset the module
function aLSTM:reset()

	self.ifgate = self:buildIFModule()
	self.zmod = self:buildUpdateModule()
	self.ogate = self:buildOGModule()

	-- inner parameters need to correctly processed
	-- in fact, it is output and cell at time step 0
	-- it contains by a module to fit Container
	self.sbm = self:buildSelfBias(self.outputSize)

	-- module used to compute the forward and backward of tanh
	-- It seems does not need to be put in self.modules
	self.tanh = nn.aTanh()

	--[[ put the modules in self.modules,
	so the default method could be done correctly]]
	self.modules = {self.ifgate, self.zmod, self.ogate, self.sbm}

	self:forget()

end

-- remember last state or not
function aLSTM:remember(mode)

	-- set default to both
	local _mode = mode or "both"

	if _mode == "both" or _mode == true then
		self.rememberState = true
	else
		self.rememberState = nil
		self:forget()
	end

end

-- build input and forget gate
function aLSTM:buildIFModule()

	local _ifm = nn.aSequential()
		:add(nn.aJoinTable(self.narrowDim,self.narrowDim))
		:add(nn.aLinear(self.inputSize + self.outputSize * 2, self.outputSize * 2))
		:add(nn.aSigmoid())

	return _ifm

end

-- build output gate
function aLSTM:buildOGModule()

	local _ogm = nn.aSequential()
		:add(nn.aJoinTable(self.narrowDim,self.narrowDim))
		:add(nn.aLinear(self.inputSize + self.outputSize * 2, self.outputSize))
		:add(nn.aSigmoid())

	return _ogm

end

-- build z(update) module
function aLSTM:buildUpdateModule()

	local _um = nn.aSequential()
		:add(nn.aJoinTable(self.narrowDim,self.narrowDim))
		:add(nn.aLinear(self.inputSize + self.outputSize, self.outputSize))
		:add(nn.aTanh())

	return _um

end

-- build a module that contains aLSTM.bias and aLSTM.gradBias to make it fit Container
function aLSTM:buildSelfBias(outputSize)

	local _smb = nn.Module()
	_smb.bias = torch.zeros(2 * outputSize)
	_smb.gradBias = _smb.bias:clone()

	return _smb

end

-- prepare for LSTM
function aLSTM:prepare()

	-- Warning: This method may be DEPRECATED at any time
	-- it is for debug use
	-- you should write a faster and simpler module instead of nn
	-- for your particular use

	nn.aJoinTable = nn.JoinTable
	nn.aLinear = nn.Linear
	nn.aTanh = nn.Tanh
	--require "aTanh"
	nn.aSigmoid = nn.Sigmoid
	nn.aSequential = nn.Sequential

end

-- mask zero for a step
function aLSTM:_step_makeZero(input, gradOutput)

	if self.batchsize then
		-- if batch input
		
		-- get a zero unit
		local _stdZero = input:narrow(1,1,1):clone():zero()
		-- look at each unit
		for _t = 1, self.batchsize do
			if input:narrow(1,_t,1):equal(_stdZero) then
				-- if it was zero, then zero the gradOutput
				gradOutput:narrow(1,_t,1):zero()
			end
		end
	else
		-- if not batch

		local _stdZero = input:clone():zero()
		if input:equal(_stdZero) then
			gradOutput:zero()
		end
	end

end

-- mask zero for a sequence
function aLSTM:_seq_makeZero(input, gradOutput)

	-- walk the whole sequence
	for _t,v in ipairs(input) do
		-- make zero for each step
		self:_step_makeZero(v,gradOutput[_t])
	end

end

-- copy a table
function aLSTM:_cloneTable(tbsrc)

	local tbrs = {}
	for k,v in ipairs(tbsrc) do
		tbrs[k] = v
	end

	return tbrs
end

-- introduce self
function aLSTM:__tostring__()

	return string.format('%s(%d -> %d)', torch.type(self), self.inputSize, self.outputSize)

end