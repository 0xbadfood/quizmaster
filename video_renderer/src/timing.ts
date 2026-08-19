import type {QuizVideoData, VideoQuestion} from './types';

export const INTRO_FRAMES = 75;
export const QUESTION_LEAD_FRAMES = 15;
export const AFTER_NARRATION_FRAMES = 15;
export const COUNTDOWN_FRAMES = 150;
export const REVEAL_LEAD_FRAMES = 30;
export const EXPLANATION_PAD_FRAMES = 24;
export const TRANSITION_FRAMES = 42;
export const FINAL_BACKGROUND_FRAMES = 75;
export const FADE_FRAMES = 12;

export const secondsToFrames = (seconds: number, fps: number) =>
  Math.ceil(seconds * fps);

export const questionTiming = (question: VideoQuestion, fps: number) => {
  const questionAudioFrames = secondsToFrames(
    question.questionAudioSeconds,
    fps,
  );
  const explanationAudioFrames = secondsToFrames(
    question.explanationAudioSeconds,
    fps,
  );
  const countdownStart =
    QUESTION_LEAD_FRAMES + questionAudioFrames + AFTER_NARRATION_FRAMES;
  const revealStart = countdownStart + COUNTDOWN_FRAMES;
  const explanationStart = revealStart + REVEAL_LEAD_FRAMES;
  const contentFrames =
    explanationStart + explanationAudioFrames + EXPLANATION_PAD_FRAMES;

  return {
    questionAudioFrames,
    explanationAudioFrames,
    countdownStart,
    revealStart,
    explanationStart,
    contentFrames,
    totalFrames: contentFrames + TRANSITION_FRAMES,
  };
};

export const totalDurationInFrames = (data: QuizVideoData) =>
  INTRO_FRAMES +
  data.questions.reduce(
    (total, question, index) =>
      total +
      questionTiming(question, data.fps).contentFrames +
      (index === data.questions.length - 1
        ? FINAL_BACKGROUND_FRAMES
        : TRANSITION_FRAMES),
    0,
  );
