export type QuizChoice = {
  choiceId: string;
  label: string;
  image: string;
};

export type VideoQuestion = {
  questionId: string;
  question: string;
  explanation: string;
  correctChoiceId: string;
  questionAudio: string;
  explanationAudio: string;
  questionAudioSeconds: number;
  explanationAudioSeconds: number;
  choices: QuizChoice[];
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
  questions: VideoQuestion[];
};
