import React from 'react';
import {Composition} from 'remotion';
import quizData from './generated-quiz.json';
import {QuizVideo} from './QuizVideo';
import {totalDurationInFrames} from './timing';
import type {QuizVideoData} from './types';

const data = quizData as QuizVideoData;

export const QuizRoot: React.FC = () => {
  return (
    <Composition
      id="QuizPrototype"
      component={QuizVideo}
      width={data.width}
      height={data.height}
      fps={data.fps}
      durationInFrames={totalDurationInFrames(data)}
      defaultProps={{data}}
    />
  );
};
