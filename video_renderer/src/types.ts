export type QuizChoice = {
  choiceId: string;
  label: string;
  image: string;
};

export type VideoQuestion = {
  questionId: string;
  questionNumber: number;
  question: string;
  explanation: string;
  correctChoiceId: string;
  questionAudio: string;
  explanationAudio: string;
  questionAudioSeconds: number;
  explanationAudioSeconds: number;
  choices: QuizChoice[];
};

export type VideoPresentationAssets = {
  progressPlaque: string;
  questionFrame: string;
  answerFrame: string;
  explanationFrame: string;
  badges: string[];
};

export type QuizVideoData = {
  schemaVersion: 'quiz_video_input_v1';
  category: string;
  title: string;
  difficulty: string;
  quizId: string;
  width: number;
  height: number;
  fps: number;
  background: string;
  timerAudio: string;
  introVideo?: string;
  introVideoSeconds?: number;
  presentation: VideoPresentationAssets;
  totalQuestions: number;
  questions: VideoQuestion[];
};
