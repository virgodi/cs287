require 'hdf5';
require 'nngraph';
require 'torch';
require 'xlua';
require 'randomkit'


function graph_model_hops_adjacent_batch(dim_hidden, num_answer, voca_size, memsize, num_hops, sentence_size, batch_size)
    -- Graph model with multiple hops set with the Adjacent approach

    -- Inputs
    story_in_memory = nn.Identity()()
    question = nn.Identity()()
    time = nn.Identity()()

    -- The initialization for C will serve for A
    C = nn.LookupTable(voca_size, dim_hidden)
    T_C = nn.LookupTable(memsize, dim_hidden)
    B = nn.LookupTable(voca_size, dim_hidden)
    -- Set B = A (use of share to have them tied all along the train)
    B:share(C,'weight', 'gradWeight', 'bias', 'gradBias')

    question_embedding = nn.View(1, dim_hidden)(nn.Sum(2)(B(question)));

    for K=1, num_hops do
        -- Initialization and A/T_A (next) = C/T_C (prev)
        A = nn.LookupTable(voca_size, dim_hidden)
        T_A = nn.LookupTable(memsize, dim_hidden)
        A:share(C,'weight', 'gradWeight', 'bias', 'gradBias')
        T_A:share(T_C,'weight', 'gradWeight', 'bias', 'gradBias')

        -- New C
        C = nn.LookupTable(voca_size, dim_hidden)
        T_C = nn.LookupTable(memsize, dim_hidden)

        -- Batch
        A_batched = nn.Sum(3)(nn.View(-1, memsize, sentence_size, dim_hidden)(A(story_in_memory)))
        C_batched = nn.Sum(3)(nn.View(-1, memsize, sentence_size, dim_hidden)(C(story_in_memory)))

        -- Transformed input
        sent_input_embedding = nn.CAddTable()({A_batched, T_A(time)});
        sent_output_embedding = nn.CAddTable()({C_batched, T_C(time)});

        -- Components
        weights = nn.SoftMax()(nn.MM(false, true)({question_embedding, sent_input_embedding}))
        o = nn.MM()({weights, sent_output_embedding})

        -- Next step
        question_embedding = nn.CAddTable()({o, question_embedding})
    end

    W = nn.Linear(dim_hidden, num_answer, false)
    -- TODO: set W^T = C (num_answer need to be size of voca_size)
    -- W:parameters()[1] = W:parameters()[1]:transpose(1,2)

    -- Final output
    output = nn.LogSoftMax()(W(nn.View(-1, dim_hidden)(question_embedding)))

    -- Model
    model = nn.gModule({story_in_memory, question, time}, {output})

    return model
end

function build_input_batch(story_memory, question_input, cleaned_sentences, cleaned_questions, questions_sentences,
                   question_index, voca_size, batch_size)
        -- Dimensions
        -- story_memory (batch_size, memsize, max_len_sentence)
        -- question_input (batch_size, max_len_question)
        -- Initialize story_memory with padding
        story_memory:fill(voca_size)
        -- Extract story and question
        for s=1,math.min(batch_size, questions_sentences:size(1) - question_index) do
            local story_start = questions_sentences[{question_index + s - 1,1}]
            local story_size = questions_sentences[{question_index + s - 1,2}] - story_start + 1
            local story = cleaned_sentences:narrow(1,story_start, story_size)
            -- Building input
            sm = story_memory:narrow(1, s, 1):view(story_memory:size(2), story_memory:size(3))
            if story_size < memsize then 
                sm:narrow(1,memsize - story_size + 1,story_size):copy(story)
            else
                sm:copy(story:narrow(1, story_size - memsize + 1, memsize))
            end
        end
        question_input:copy(cleaned_questions:narrow(1, question_index, batch_size))
end

function accuracy_batch(sentences, questions, questions_sentences, answers, model, memsize, voca_size,
                  dim_hidden, batch_size)
    local acc = 0
    local story_memory_batch = torch.ones(batch_size, memsize, sentences:size(2)-1)*voca_size
    local story_memory_batch_sized = torch.ones(batch_size, memsize * (sentences:size(2)-1))
    -- Clean sentence and question while removing the the task_id
    local cleaned_sentences = sentences:narrow(2,2,sentences:size(2)-1)
    local cleaned_questions = questions:narrow(2, 2, questions:size(2)-1)
    -- To store the quesiton input
    local time_input_batch = torch.linspace(1,memsize,memsize):type('torch.LongTensor'):repeatTensor(batch_size,1)
    local question_input_batch = torch.zeros(batch_size, cleaned_questions:size(2))

    for i = 1, questions:size(1), batch_size do
        -- TOFIX: we cut the last questions if not enough for a batch
        if (batch_size > questions_sentences:size(1) - i) then
            break
        end
        build_input_batch(story_memory_batch, question_input_batch, cleaned_sentences, cleaned_questions, questions_sentences,
                           i, voca_size, batch_size)
        story_memory_batch_sized:copy(torch.view(story_memory_batch, batch_size, -1))
        input = {story_memory_batch_sized, question_input_batch, time_input_batch}
        pred = model:forward(input)
        -- print('pred is ', pred)

        m, a = pred:max(2)
        answer = answers:narrow(1,i,batch_size):view(batch_size)
        -- print('argmax is ', a)
        -- print('answer is ', answer)
        for s=1, batch_size do
            if a[s][1] == answer[s] then
                acc = acc + 1
            end
        end
    end
    -- TOFIX: denom adapted if droped input because of batch size
    denom = questions
    return acc/questions:size(1)
end


function train_model_batch(sentences, questions, questions_sentences, answers, model, par, gradPar,
                     criterion, eta, nEpochs, memsize, voca_size, batch_size)
    -- Train the model with a SGD

    -- To store the loss
    local loss = torch.zeros(nEpochs)
    local accuracy_tensor = torch.zeros(nEpochs)
    local av_L = 0

    local story_memory_batch = torch.ones(batch_size, memsize, sentences:size(2)-1)*voca_size
    local story_memory_batch_sized = torch.ones(batch_size, memsize * (sentences:size(2)-1))
    -- Clean sentence and question while removing the the task_id
    local cleaned_sentences = sentences:narrow(2,2,sentences:size(2)-1)
    local cleaned_questions = questions:narrow(2, 2, questions:size(2)-1)
    -- To store the quesiton input
    local time_input_batch = torch.linspace(1,memsize,memsize):type('torch.LongTensor'):repeatTensor(batch_size,1)
    local question_input_batch = torch.zeros(batch_size, cleaned_questions:size(2))


    for i = 1, nEpochs do
        -- timing the epoch
        timer = torch.Timer()
        av_L = 0
        if i % 25 == 0 and i < 100 then
            eta = eta/2
        end
        -- mini batch loop
        for i = 1, questions:size(1), batch_size do
            -- TOFIX: we cut the last questions if not enough for a batch
            if (batch_size > questions_sentences:size(1) - i) then
                break
            end
            build_input_batch(story_memory_batch, question_input_batch, cleaned_sentences, cleaned_questions, questions_sentences,
                               i, voca_size, batch_size)
            story_memory_batch_sized:copy(torch.view(story_memory_batch, batch_size, -1))
            input = {story_memory_batch_sized, question_input_batch, time_input_batch}

            -- reset gradients
            model:zeroGradParameters()

            -- Forward pass (selection of inputs_batch in case the batch is not full, ie last batch)
            pred = model:forward(input)
            -- Average loss computation
            f = criterion:forward(pred, answers:narrow(1,i,batch_size):view(batch_size))
            av_L = av_L +f

            -- Backward pass
            df_do = criterion:backward(pred, answers:narrow(1,i,batch_size):view(batch_size))
            model:backward(input, df_do)

            -- gradient normalization with max norm 40 (l2 norm)
            gradPar:view(gradPar:size(1),1):renorm(1,2,40)
            model:updateParameters(eta)
            --par:add(gradPar:mul(-eta))
            
        end
        accuracy_tensor[i] = accuracy_batch(sentences, questions, questions_sentences, answers, model, memsize, voca_size,
                                      dim_hidden, batch_size)
        loss[i] = av_L/questions:size(1)
        print('Epoch '..i..': '..timer:time().real)
        print('\n')
        print('Average Loss: '.. loss[i])
        print('\n')
        print('Training accuracy: '.. accuracy_tensor[i])
        print('\n')
        print('***************************************************')
       
    end
    return loss, accuracy_tensor
end

-- ------------ Main pipeline

-- myFile = hdf5.open('../Data/preprocess/task123_train.hdf5','r')
-- f = myFile:all()
-- sentences = f['sentences']
-- questions = f['questions']
-- questions_sentences = f['questions_sentences']
-- answers = f['answers']
-- voca_size = f['voc_size'][1]
-- myFile:close()

-- -- Building the model
-- memsize = 50
-- nEpochs = 100
-- eta = 0.01
-- dim_hidden = 50
-- num_hops = 3
-- num_answer = torch.max(answers)
-- batch_size = 16
-- sentence_size = sentences:size(2) - 1
-- model = graph_model_hops_adjacent_batch(dim_hidden, num_answer, voca_size, memsize,
--                                         num_hops, sentence_size, batch_size)

-- -- Initialise parameters using normal(0,0.1) as mentioned in the paper
-- parameters, gradParameters = model:getParameters()
-- torch.manualSeed(0)
-- randomkit.normal(parameters, 0, 0.1)

-- -- -- Criterion
-- criterion = nn.ClassNLLCriterion()

-- -- Cuda
-- -- loss_train, accuracy_train = train_model_batch(sentences:cuda(), questions:cuda(), questions_sentences:cuda(), answers:cuda(),
-- --                                          model:cuda(), parameters, gradParameters, criterion:cuda(), eta,
-- --                                          nEpochs, memsize, voca_size, batch_size)

-- -- Batch training
-- -- loss_train, accuracy_train = train_model_batch(sentences, questions, questions_sentences, answers,
-- --                                          model, parameters, gradParameters, criterion, eta,
-- --                                          nEpochs, memsize, voca_size, batch_size)


-- -- Testing batch

-- cleaned_sentences = sentences:narrow(2,2,sentences:size(2)-1)
-- cleaned_questions = questions:narrow(2, 2, questions:size(2)-1)

-- time_input_batch = torch.linspace(1,memsize,memsize):type('torch.LongTensor'):repeatTensor(batch_size,1)
-- story_memory_batch = torch.ones(batch_size, memsize, sentences:size(2)-1)*voca_size
-- question_input_batch = torch.zeros(batch_size, cleaned_questions:size(2))

-- build_input_batch(story_memory_batch, question_input_batch, cleaned_sentences, cleaned_questions, questions_sentences,
--                    1, voca_size, batch_size)
-- print(story_memory_batch:size(), question_input_batch:size(), time_input_batch:size())

-- input_batch = {story_memory_batch:view(batch_size, -1), question_input_batch, time_input_batch}
-- pred = model:forward(input_batch)
-- print(pred:size())


-- function main()
--     -- Parsing arg
--     opt = cmd:parse(arg)

--     myFile = hdf5.open('../Data/preprocess/'.. opt.filename ..'_train.hdf5','r')
--     f = myFile:all()
--     sentences = f['sentences']
--     questions = f['questions']
--     questions_sentences = f['questions_sentences']
--     answers = f['answers']
--     voca_size = f['voc_size'][1]
--     myFile:close()

--     -- Building the model
--     batch_size = opt.batchsize
--     memsize = opt.mem
--     nEpochs = opt.nepochs
--     eta = 0.01
--     dim_hidden = 50
--     num_hops = opt.hops
--     num_answer = torch.max(answers)
--     sentence_size = sentences:size(2) - 1
--     -- model = graph_model(dim_hidden, num_answer, voca_size, memsize)
--     if opt.adjacent == 1 then
--         model = graph_model_hops_adjacent(dim_hidden, num_answer, voca_size, memsize, num_hops)
--     else
--         model = graph_model_hops_rnn_like(dim_hidden, num_answer, voca_size, memsize, num_hops)
--     end

--     -- Initialise parameters using normal(0,0.1) as mentioned in the paper
--     parameters, gradParameters = model:getParameters()
--     torch.manualSeed(0)
--     randomkit.normal(parameters, 0, 0.1)

--     -- -- Criterion
--     criterion = nn.ClassNLLCriterion()

--     -- -- Training
--     loss_train, accuracy_tensor_train = train_model(sentences, questions, questions_sentences, answers,
--                                              model, parameters, gradParameters, criterion, eta,
--                                              nEpochs, memsize, voca_size)

--     accuracy_train, accuracy_by_task_train = accuracy(sentences, questions,
--                                                       questions_sentences, answers,
--                                                       model, memsize, voca_size, dim_hidden)

--     print('Train accuracy TOTAL '.. accuracy_train)
--     print('Train accuracy by task')
--     print(accuracy_by_task_train)
--     print('\n')
--     print('***************************************************')
--     -- Prediction on test
--     myFile = hdf5.open('../Data/preprocess/'.. opt.filename ..'_test.hdf5','r')
--     f = myFile:all()
--     sentences_test = f['sentences']
--     questions_test = f['questions']
--     questions_sentences_test = f['questions_sentences']
--     answers_test = f['answers']
--     voca_size = f['voc_size'][1]
--     myFile:close()

--     accuracy_test, accuracy_by_task_test = accuracy(sentences_test, questions_test,
--                                                     questions_sentences_test, answers_test,
--                                                     model, memsize, voca_size, dim_hidden)
--     print('Test accuracy TOTAL '.. accuracy_test)
--     print('Test accuracy by task')
--     print(accuracy_by_task_test)
--     print('\n')
--     print('***************************************************')

--     -- Saving the final accuracies
--     fname = opt.filename .. '_' ..num_hops..'hops_'.. opt.adjacent..'adjacent.acc_by_task.hdf5'
--     myFile = hdf5.open(fname, 'w')
--     myFile:write('train', accuracy_by_task_train)
--     myFile:write('test', accuracy_by_task_test)
--     myFile:close()
--     print('Accuracy by task saved at '.. fname)
-- end

-- main()
